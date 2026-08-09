#include "../pch.h"
#include "../osxup.h"
#include "PaintManager.h"
#include "osxrdp/packet.h"
#include "PaintBitmap.h"
#include "PaintH264.h"
#include "PaintRFX.h"
#include "utils.h"

static const char* OSXRDP_SCREENSHM_NAME = "/osxrdpshm";
static const char* OSXRDP_CURSORSHM_NAME = "/osxrdpcursorshm";

PaintManager::PaintManager() :
    _inited(false),
    _mod(NULL),
    _paint(NULL),
    _cursorShm(NULL),
    _inPainting(false),
    _releasePending(false),
    _nextFrameGeneration(1),
    _freeInFlightCount(0),
    _inFlightHead(0),
    _inFlightCount(0),
    _recordShmCnt(0)
{
    for (int i = 0; i < 16; i++) {
        _recordShm[i] = NULL;
        _needPaintDisplay[i] = 0;
        _inFlightCountByDisplay[i] = 0;
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

    if (_inFlightCount >= FRAME_SLOTS * _recordShmCnt) {
        return;
    }

    for (int i = 0; i < _recordShmCnt; i++) {
        // 그릴 수 있는 유효한 디스플레이인지 확인
        if (_recordShm[i] == NULL)
            continue;

        _needPaintDisplay[i] = 0;

        // Retry a deferred full-repaint rollback. For self-contained formats the
        // consumer_request_full flag is set only by RequestFullRepaint and cleared
        // only by a successful rollback or by the producer servicing it with a
        // full capture frame, so flag == 1 means the request is still unserviced.
        // Retrying here every paint tick closes the race where a producer commit
        // deferred the rollback and a then-static screen would otherwise wait for
        // the next screen change. Cheap no-op (one atomic load) when the flag is 0.
        screenrecord_shm_t* retryShm = (screenrecord_shm_t*)_recordShm[i]->mem;
        if (atomic_load_explicit(&retryShm->consumer_request_full, memory_order_acquire) == 1) {
            TryResubmitLastFrame(i);
        }

        // in-flight 여유가 있는 동안 최대 3회 paint
        int cnt = 0;
        while (_inFlightCountByDisplay[i] < FRAME_SLOTS && cnt < 3) {
            screenrecord_frame_t* frameInfo = NULL;
            char* imgData = NULL;
            size_t imgDataSize = 0;
            int width = 0;
            int height = 0;
            unsigned int shm_frame_id = 0;

            // 읽을 데이터가 있는지 확인
            if (GetPaintData(&frameInfo, &imgData, &imgDataSize, &width, &height, &shm_frame_id, i) == false) {
                break;
            }

            unsigned int frame_id = 0;
            if (PushInFlight(i, shm_frame_id, &frame_id) == false) {
                break;
            }
            _inPainting = (_inFlightCount > 0);

            // 그리기
            _paint->DoPaint(_mod, frameInfo, imgData, imgDataSize, frame_id, i, width, height);

            cnt++;
        }
    }
}

bool PaintManager::GetPaintData(screenrecord_frame_t** outFrameInfo, char** outImgData, size_t* outImgDataSize, int* outWidth, int* outHeight, unsigned int* frame_id, int displayIdx) {
    screenrecord_shm_t* shm = (screenrecord_shm_t*)_recordShm[displayIdx]->mem;

    // 읽을 데이터가 있는지 확인
    unsigned int read_pos = atomic_load_explicit(&shm->read_pos,  memory_order_acquire);
    unsigned int write_pos = atomic_load_explicit(&shm->write_pos, memory_order_acquire);

    if (read_pos == write_pos) {
        return false;
    }

    int forceRedrawAll = 0;
    int displayInFlightCount = _inFlightCountByDisplay[displayIdx];
    unsigned int targetPos = read_pos + (unsigned int)displayInFlightCount;
    if (targetPos >= write_pos) {
        return false;
    }

    bool selfContained = (_paint == NULL || _paint->FrameIsSelfContained() == true);
    bool trueBacklog = (displayInFlightCount == 0 && (write_pos - read_pos >= FRAME_SLOTS));

    // backlog 를 처리하는 방법
    //   - self-contained 포맷 (BGRA32 / NV12) : 최신 slot 으로 점프해서 full 로 처리.
    //   - partial-frame 포맷 (RFX)            : 중간 dirty tile 을 재구성할 수 없으므로 backlog 전체를 drop 하고 producer 에게 full redraw 를 요청. 이번 paint 는 무시.
    if (selfContained == false) {
        if (trueBacklog == true) {
            atomic_store_explicit(&shm->consumer_request_full, 1, memory_order_release);
            atomic_store_explicit(&shm->read_pos, write_pos, memory_order_release);
            return false;
        }
    }
    else {
        if (trueBacklog == true || (displayInFlightCount == 0 && read_pos == 0)) {
            targetPos = write_pos - 1;
            forceRedrawAll = 1;
        }
    }

    unsigned int idx = targetPos % FRAME_SLOTS;
    screenrecord_frame_t* frame = &(shm->frames[idx]);
    char* imgData = *(&shm->screenrecord_datas + (size_t)shm->screenrecord_data_size * idx);

    size_t imgDataSize = 0;
    memcpy(&imgDataSize, imgData, sizeof(size_t));

    // abnormal data --> skip it
    if (imgDataSize == 0 || imgDataSize > shm->screenrecord_data_size)
        return false;

    if (forceRedrawAll != 0) {
        frame->dirtyCount = 0;
    }

    *outFrameInfo = frame;
    *outImgData = imgData + sizeof(size_t);
    *outImgDataSize = imgDataSize;
    *outWidth = shm->width;
    *outHeight = shm->height;

    *frame_id = targetPos;

    //atomic_store_explicit(&shm->read_pos, read_pos + 1, memory_order_release);

    return true;
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

    if (_inFlightCountByDisplay[displayIdx] >= FRAME_SLOTS) {
        return false;
    }

    if (_nextFrameGeneration >= 0x7FFFFFFFU / IN_FLIGHT_SLOT_COUNT) {
        if (_inFlightCount > 0) {
            return false;
        }
        _nextFrameGeneration = 1;
    }

    int slot = _freeInFlightSlots[--_freeInFlightCount];
    unsigned int frameId = (_nextFrameGeneration * IN_FLIGHT_SLOT_COUNT) + (unsigned int)slot;
    _nextFrameGeneration++;

    _inFlightFrames[slot].frameId = frameId;
    _inFlightFrames[slot].displayIdx = displayIdx;
    _inFlightFrames[slot].shmReadPos = shmReadPos;
    _inFlightFrames[slot].inUse = true;

    int tail = (_inFlightHead + _inFlightCount) % IN_FLIGHT_SLOT_COUNT;
    _inFlightSlotQueue[tail] = slot;

    _inFlightCount++;
    _inFlightCountByDisplay[displayIdx]++;
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
        _inFlightCountByDisplay[i] = 0;
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

void PaintManager::RequestFullRepaint() {
    if (_inited == false) {
        return;
    }

    for (int i = 0; i < 16; i++) {
        if (_recordShm[i] == NULL) {
            continue;
        }

        screenrecord_shm_t* shm = (screenrecord_shm_t*)_recordShm[i]->mem;
        atomic_store_explicit(&shm->consumer_request_full, 1, memory_order_release);

        // For self-contained formats, try to service the request immediately by
        // re-exposing the last committed frame. If a producer commit races this,
        // the flag stays set and Paint() retries on the next paint tick.
        TryResubmitLastFrame(i);
    }
}

bool PaintManager::TryResubmitLastFrame(int displayIdx) {
    // Self-contained formats (BGRA32 / NV12) keep a complete image in every
    // slot, so when the ring is idle the last committed frame can be
    // re-submitted as a full repaint right away. Without this a fully static
    // screen would stay blank until the capture pipeline produces a new frame
    // (capture is change-driven). RFX slots are dirty-only and cannot be
    // re-submitted — that path relies on the producer flag.
    if (_paint == NULL || _paint->FrameIsSelfContained() == false) {
        return false;
    }

    if (_inFlightCountByDisplay[displayIdx] != 0) {
        return false;
    }

    screenrecord_shm_t* shm = (screenrecord_shm_t*)_recordShm[displayIdx]->mem;

    unsigned int write_pos = atomic_load_explicit(&shm->write_pos, memory_order_acquire);
    unsigned int read_pos = atomic_load_explicit(&shm->read_pos, memory_order_acquire);

    // Only when every produced frame has been consumed and at least one exists
    if (write_pos == 0 || read_pos != write_pos) {
        return false;
    }

    // Publish the rollback first: once read_pos < write_pos is visible, the
    // producer's ring fullness check keeps it at least one slot away from the
    // re-exposed one. Note this relies on the producer observing the rolled-back
    // read_pos within the next ~FRAME_SLOTS-2 commits (cache-coherence
    // timeliness, not a happens-before edge) — unreachable in practice, and the
    // ring self-heals via the backlog jump in GetPaintData if it were violated.
    atomic_store_explicit(&shm->read_pos, write_pos - 1, memory_order_release);

    // If the producer committed a frame meanwhile it may own that slot — leave
    // the header alone; the consumer_request_full flag covers the repaint then
    if (atomic_load_explicit(&shm->write_pos, memory_order_acquire) != write_pos) {
        return false;
    }

    unsigned int idx = (write_pos - 1) % FRAME_SLOTS;
    shm->frames[idx].dirtyCount = 0;

    // The re-submitted frame services the request — clear the flag so the next
    // capture frame does not redo the full redraw
    atomic_store_explicit(&shm->consumer_request_full, 0, memory_order_release);
    return true;
}

void PaintManager::PaintMouseCursor() {
    cursor_data_t* cursorData = (cursor_data_t*)_cursorShm->mem;

    int updated = atomic_load_explicit(&cursorData->updated,  memory_order_acquire);
    if (updated == 1) {
        _mod->server_set_pointer_large((struct mod*)_mod, cursorData->hotspotX, cursorData->hotspotY, cursorData->cursorImgData, cursorData->cursorMaskData, 32, cursorData->width, cursorData->height);

        atomic_store_explicit(&cursorData->updated, 0, memory_order_release);
    }
}
