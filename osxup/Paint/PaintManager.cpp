#include "../pch.h"
#include "../osxup.h"
#include "PaintManager.h"
#include "osxrdp/packet.h"
#include "PaintBitmap.h"
#include "PaintH264.h"
#include "PaintRFX.h"
#include "utils.h"
#include <limits.h>
#include <sys/mman.h>

static const char* OSXRDP_SCREENSHM_NAME = "/osxrdpshm";
static const char* OSXRDP_CURSORSHM_NAME = "/osxrdpcursorshm";

PaintManager::PaintManager() :
    _inited(false),
    _mod(NULL),
    _paint(NULL),
    _cursorShm(NULL),
    _inPainting(false),
    _releasePending(false),
    _nextFrameId(1),
    _maxInFlightFrames(FRAME_SLOTS),
    _freeInFlightCount(0),
    _inFlightHead(0),
    _inFlightCount(0),
    _recordShmCnt(0)
{
    for (int i = 0; i < 16; i++) {
        _recordShm[i] = NULL;
        _needPaintDisplay[i] = 0;
        _inFlightCountByDisplay[i] = 0;
        _nextSubmitPos[i] = 0;
    }
}

PaintManager::~PaintManager() {
    Release();
}

int PaintManager::CheckRecordFormat(const struct mod* mod) {
    assert(mod != NULL);
    if (mod == NULL) return -1;
    
    if (mod->client_info.gfx == 1) {
        if (mod->client_info.capture_code == CC_GFX_A2) {
            // using H.264
            if (mod->usevtoolbox == 1) {
                return OSXRDP_RECORDFORMAT_NV12_ALIGNED;
            }
            else {
                return OSXRDP_RECORDFORMAT_NV12_PACKED;
            }
        }
        
        return OSXRDP_RECORDFORMAT_RFX;
    }
    else {
        return OSXRDP_RECORDFORMAT_BGRA32;
    }
}

int PaintManager::Initialize(const struct mod* mod, int recordFormat, int sessionId, bool isLockScreen) {
    assert(mod != NULL);
    assert(recordFormat >= 0);
    assert(_recordShmCnt == 0);
    assert(_inited == false);
    
    if (_inited == true) {
        return false;
    }
    
    if (mod == NULL || recordFormat < 0) {
        // log
        return false;
    }
    
    char shm_name[512] = {0,};
    int monitorCount = mod->client_info.display_sizes.monitorCount;
    if (monitorCount == 0) {
        monitorCount = 1;
    }

    if (monitorCount > 16) {
        monitorCount = 16;
    }

    if (get_object_name(sessionId, OSXRDP_SCREENSHM_NAME, shm_name, sizeof(shm_name), isLockScreen) == 0) {
        // log
        return false;
    }

    for (int i = 0; i < monitorCount; i++) {
        char shm_name_with_idx[512];
        snprintf(shm_name_with_idx, sizeof(shm_name_with_idx), "%s_%d", shm_name, i);

        // lockscreen 처럼 일부 output monitor 에만 SHM 이 존재할 수 있다.
        _recordShm[i] = xshm_open(shm_name_with_idx);

        if (mod->client_info.display_sizes.monitorCount == 0 && _recordShm[i] == NULL) {
            // log
            return false;
        }

        _recordShmCnt++;
    }
    
    if (get_object_name(sessionId, OSXRDP_CURSORSHM_NAME, shm_name, sizeof(shm_name), isLockScreen) == 0) {
        // log
        return false;
    }
    
    // 마우스 커서 데이터가 담긴 공유 메모리를 열기
    _cursorShm = xshm_open(shm_name);
    if (_cursorShm == NULL) {
        // log
        return false;
    }
    
    if (recordFormat == OSXRDP_RECORDFORMAT_NV12_PACKED || recordFormat == OSXRDP_RECORDFORMAT_NV12_ALIGNED) {
        _paint = new PaintH264();
    }
    else if (recordFormat == OSXRDP_RECORDFORMAT_RFX) {
        _paint = new PaintRFX();
    }
    else {
        _paint = new PaintBitmap();
    }
    
    // painter initialize
    _paint->Initialize(mod);
    _maxInFlightFrames = _paint->MaxInFlightFrames();

    _mod = mod;
    _releasePending = false;
    ResetInFlight();
    
    _inited = true;
    
    return true;
}

void PaintManager::Release() {
    _releasePending = false;
    ReleaseResources();
}

bool PaintManager::TryReleaseForReconnect() {
    if (_inited == false && _recordShmCnt == 0 && _cursorShm == NULL && _paint == NULL) {
        return true;
    }

    _releasePending = true;

    if (_inFlightCount > 0) {
        return false;
    }

    ReleaseResources();
    _releasePending = false;
    return true;
}

void PaintManager::ReleaseResources() {
    if (_paint != NULL) {
        _paint->Release();
        
        delete _paint;
        _paint = NULL;
    }

    // close shm
    for (int i = 0; i < 16; i++) {
        if (_recordShm[i] != NULL) {
            xshm_close(_recordShm[i]);
            xshm_destroy(_recordShm[i]);
            _recordShm[i] = NULL;
        }
        
        _needPaintDisplay[i] = 0;
    }
    _recordShmCnt = 0;
    
    if (_cursorShm != NULL) {
        xshm_close(_cursorShm);
        xshm_destroy(_cursorShm);
        
        _cursorShm = NULL;
    }
    
    _mod = NULL;
    ResetInFlight();
    _inPainting = false;
    _releasePending = false;
    _inited = false;
}

void PaintManager::Paint() {
    if (_inited == false || _paint == NULL || _recordShmCnt == 0 || _cursorShm == NULL) {
        return;
    }

    // 재접속 중에는 이전 공유메모리에 대한 신규 paint 제출을 중지하고
    // 기존 in-flight 프레임 ACK만 기다린다.
    if (_releasePending == true) {
        return;
    }
    
    // 마우스 커서 그리기
    PaintMouseCursor();
    
    if (_inFlightCount >= _maxInFlightFrames * _recordShmCnt) {
        return;
    }
    
    for (int i = 0; i < _recordShmCnt; i++) {
        // 그릴 수 있는 유효한 디스플레이인지 확인
        if (_recordShm[i] == NULL)
            continue;

        _needPaintDisplay[i] = 0;

        // in-flight 여유가 있는 동안 최대 3회 paint
        int cnt = 0;
        while (_inFlightCountByDisplay[i] < _maxInFlightFrames && cnt < 3) {
            screenrecord_frame_t frameInfo;
            char* imgData = NULL;
            size_t imgDataSize = 0;
            int width = 0;
            int height = 0;
            unsigned int shm_frame_id = 0;

            // 읽을 데이터가 있는지 확인
            if (GetPaintData(&frameInfo, &imgData, &imgDataSize, &width, &height, &shm_frame_id, i) == false) {
                break;
            }

            char* payload = imgData;
            size_t payloadBytes = imgDataSize;

            // xrdp 가 이미지 데이터를 비동기로 읽고 직접 munmap 하는 포맷 (h.264)을 위해 새 메모리를 넘긴다.
            if (_paint->NeedsOwnedPayload() == true) {
                screenrecord_shm_t* shm = (screenrecord_shm_t*)_recordShm[i]->mem;
                size_t mapOffset = (size_t)shm->screenrecord_data_offset
                                 + (size_t)shm->screenrecord_data_size * (shm_frame_id % FRAME_SLOTS)
                                 + OSXRDP_SLOT_DATA_OFFSET;

                payloadBytes = (size_t)shm->screenrecord_data_size - OSXRDP_SLOT_DATA_OFFSET;
                payload = (char*)mmap(NULL, payloadBytes, PROT_READ, MAP_SHARED, _recordShm[i]->fd, (off_t)mapOffset);
                if (payload == MAP_FAILED) {
                    break;
                }
            }

            unsigned int frame_id = 0;
            if (PushInFlight(i, shm_frame_id, &frame_id) == false) {
                if (payload != imgData) {
                    munmap(payload, payloadBytes);
                }
                break;
            }
            
            _inPainting = (_inFlightCount > 0);

            // 그리기
            _paint->DoPaint(_mod, &frameInfo, payload, payloadBytes, frame_id, i, width, height);
            
            cnt++;
        }
    }
}

bool PaintManager::GetPaintData(screenrecord_frame_t* outFrameInfo, char** outImgData, size_t* outImgDataSize, int* outWidth, int* outHeight, unsigned int* frame_id, int displayIdx) {
    screenrecord_shm_t* shm = (screenrecord_shm_t*)_recordShm[displayIdx]->mem;

    // 읽을 데이터가 있는지 확인
    unsigned int read_pos = atomic_load_explicit(&shm->read_pos,  memory_order_acquire);
    unsigned int write_pos = atomic_load_explicit(&shm->write_pos, memory_order_acquire);

    if (read_pos == write_pos) {
        return false;
    }

    int forceRedrawAll = 0;
    int displayInFlightCount = _inFlightCountByDisplay[displayIdx];
    unsigned int targetPos = _nextSubmitPos[displayIdx];
    if (targetPos >= write_pos) {
        return false;
    }

    const bool trueBacklog = (displayInFlightCount == 0 && (write_pos - read_pos >= FRAME_SLOTS));
    const unsigned int beginPos = targetPos;
    const bool mergePending = _paint->CanMergePendingFrames();
    if (mergePending) {
        // 최신 프레임과 이미 온 프레임들의 dirty 정보를 merge할 수 있도록
        targetPos = write_pos - 1;

        // 첫 프레임은 full redraw
        if (displayInFlightCount == 0 && read_pos == 0)
            forceRedrawAll = 1;
    }
    else if (trueBacklog || (displayInFlightCount == 0 && read_pos == 0)) {
        // 최신 프레임으로 jump
        targetPos = write_pos - 1;
        forceRedrawAll = 1;
    }

    unsigned int idx = targetPos % FRAME_SLOTS;
    screenrecord_frame_t* frame = &(shm->frames[idx]);
    char* imgData = (char*)shm + shm->screenrecord_data_offset
                  + (size_t)shm->screenrecord_data_size * idx;

    size_t imgDataSize = 0;
    memcpy(&imgDataSize, imgData, sizeof(size_t));

    // abnormal data --> skip it
    if (imgDataSize == 0 || imgDataSize > (size_t)shm->screenrecord_data_size - OSXRDP_SLOT_DATA_OFFSET)
        return false;

    if (shm->width <= 0 || shm->height <= 0)
        return false;

    if (mergePending) {
        MergeDirtyFrames(shm, beginPos, targetPos + 1, outFrameInfo);
    }
    else {
        *outFrameInfo = *frame;
    }

    if (forceRedrawAll != 0)
        outFrameInfo->dirtyCount = 0; // 강제 full redraw

    *outImgData = imgData + OSXRDP_SLOT_DATA_OFFSET;
    *outImgDataSize = imgDataSize;
    *outWidth = shm->width;
    *outHeight = shm->height;

    *frame_id = targetPos;

    return true;
}

void PaintManager::MergeDirtyFrames(const screenrecord_shm_t* shm, unsigned int begin, unsigned int end, screenrecord_frame_t* frame) {
    frame->dirtyCount = 0;
    
    for (unsigned int pos = begin; pos < end; pos++) {
        const screenrecord_frame_t* src = &shm->frames[pos % FRAME_SLOTS];
        
        // 한도 초과. full refresh
        if (src->dirtyCount <= 0 || src->dirtyCount > MAX_DIRTY_COUNT) {
            frame->dirtyCount = 0;
            return;
        }

        for (int i = 0; i < src->dirtyCount; i++) {
            const RECT* rect = &src->dirtys[i];
            bool contained = false;
            for (int j = 0; j < frame->dirtyCount; ) {
                RECT* current = &frame->dirtys[j];
                if (rect->x >= current->x && rect->y >= current->y &&
                    rect->x + rect->width <= current->x + current->width &&
                    rect->y + rect->height <= current->y + current->height) {
                    contained = true;
                    break;
                }
                
                if (current->x >= rect->x && current->y >= rect->y &&
                    current->x + current->width <= rect->x + rect->width &&
                    current->y + current->height <= rect->y + rect->height) {
                    // 새 영역에 포함되는 기존 항목은 마지막 항목으로 대체
                    *current = frame->dirtys[--frame->dirtyCount];
                    continue;
                }
                
                j++;
            }
            
            if (contained)
                continue;
            
            if (frame->dirtyCount >= MAX_DIRTY_COUNT) {
                frame->dirtyCount = 0;
                return;
            }
            
            frame->dirtys[frame->dirtyCount++] = *rect;
        }
    }
}

bool PaintManager::PushInFlight(int displayIdx, unsigned int shmReadPos, unsigned int* outFrameId) {
    if (displayIdx < 0 || displayIdx >= 16) {
        return false;
    }

    if (outFrameId == NULL) {
        return false;
    }

    if (_freeInFlightCount <= 0) {
        return false;
    }

    if (_inFlightCountByDisplay[displayIdx] >= _maxInFlightFrames) {
        return false;
    }

    if (_nextFrameId >= INT_MAX) {
        if (_inFlightCount == 0) {
            _mod->connectionManager->Terminate();
        }
        return false;
    }

    int slot = _freeInFlightSlots[--_freeInFlightCount];
    unsigned int frameId = _nextFrameId++;

    _inFlightFrames[slot].frameId = frameId;
    _inFlightFrames[slot].displayIdx = displayIdx;
    _inFlightFrames[slot].shmReadPos = shmReadPos;
    _inFlightFrames[slot].inUse = true;

    int tail = (_inFlightHead + _inFlightCount) % IN_FLIGHT_SLOT_COUNT;
    _inFlightSlotQueue[tail] = slot;

    _inFlightCount++;
    _inFlightCountByDisplay[displayIdx]++;
    _nextSubmitPos[displayIdx] = shmReadPos + 1;
    *outFrameId = frameId;
    return true;
}

int PaintManager::PopAckedInFlight(int ackFrameId, unsigned int* outMaxReadPosByDisplay, bool* outHasReadPosByDisplay) {
    int popped = 0;

    while (_inFlightCount > 0) {
        int slot = _inFlightSlotQueue[_inFlightHead];
        InFlightFrame* frame = &_inFlightFrames[slot];

        if (ackFrameId >= 0 && (int)frame->frameId > ackFrameId) {
            break;
        }

        int displayIdx = frame->displayIdx;
        if (displayIdx >= 0 && displayIdx < 16) {
            if (outMaxReadPosByDisplay != NULL) {
                outMaxReadPosByDisplay[displayIdx] = frame->shmReadPos;
            }
            if (outHasReadPosByDisplay != NULL) {
                outHasReadPosByDisplay[displayIdx] = true;
            }
            if (_inFlightCountByDisplay[displayIdx] > 0) {
                _inFlightCountByDisplay[displayIdx]--;
            }
        }

        frame->inUse = false;
        _freeInFlightSlots[_freeInFlightCount++] = slot;
        _inFlightHead = (_inFlightHead + 1) % IN_FLIGHT_SLOT_COUNT;
        _inFlightCount--;
        popped++;
    }

    return popped;
}

void PaintManager::ResetInFlight() {
    _freeInFlightCount = IN_FLIGHT_SLOT_COUNT;
    _inFlightHead = 0;
    _inFlightCount = 0;
    for (int i = 0; i < IN_FLIGHT_SLOT_COUNT; i++) {
        _inFlightFrames[i].frameId = 0;
        _inFlightFrames[i].displayIdx = 0;
        _inFlightFrames[i].shmReadPos = 0;
        _inFlightFrames[i].inUse = false;
        _inFlightSlotQueue[i] = 0;
        _freeInFlightSlots[i] = i;
    }
    for (int i = 0; i < 16; i++) {
        screenrecord_shm_t* shm = _recordShm[i] == NULL ? NULL : (screenrecord_shm_t*)_recordShm[i]->mem;
        _inFlightCountByDisplay[i] = 0;
        _nextSubmitPos[i] = shm == NULL ? 0 : atomic_load_explicit(&shm->read_pos, memory_order_acquire);
    }
}

void PaintManager::PaintEnd(int ackFrameId) {
    if (_inited == false || _recordShmCnt == 0) {
        _inPainting = false;
        return;
    }
    
    if (_inFlightCount <= 0) {
        _inPainting = false;
        return;
    }

    unsigned int maxReadPosByDisplay[16] = {0,};
    bool hasReadPosByDisplay[16] = {false,};

    int popped = PopAckedInFlight(ackFrameId, maxReadPosByDisplay, hasReadPosByDisplay);
    if (popped <= 0) {
        _inPainting = (_inFlightCount > 0);
        return;
    }

    for (int i = 0; i < _recordShmCnt; i++) {
        if (hasReadPosByDisplay[i] == false) {
            continue;
        }
        
        screenrecord_shm_t* shm = (screenrecord_shm_t*)_recordShm[i]->mem;
        unsigned int read_pos = atomic_load_explicit(&shm->read_pos, memory_order_relaxed);
        unsigned int nextReadPos = maxReadPosByDisplay[i] + 1;

        if (nextReadPos > read_pos) {
            atomic_store_explicit(&shm->read_pos, nextReadPos, memory_order_release);
        }
    }
    
    _inPainting = (_inFlightCount > 0);
}

void PaintManager::PaintMouseCursor() {
    cursor_data_t* cursorData = (cursor_data_t*)_cursorShm->mem;
    
    int updated = atomic_load_explicit(&cursorData->updated,  memory_order_acquire);
    if (updated == 1) {
        _mod->server_set_pointer_large((struct mod*)_mod, cursorData->hotspotX, cursorData->hotspotY, cursorData->cursorImgData, cursorData->cursorMaskData, 32, cursorData->width, cursorData->height);
        
        atomic_store_explicit(&cursorData->updated, 0, memory_order_release);
    }
}
