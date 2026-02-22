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
static const int OSXRDP_DEFAULT_MAX_IN_FLIGHT = 3;
static const int OSXRDP_MIN_MAX_IN_FLIGHT = 1;
static const int OSXRDP_MAX_MAX_IN_FLIGHT = 8;

PaintManager::PaintManager() :
    _mod(NULL),
    _paint(NULL),
    _recordShm(NULL),
    _cursorShm(NULL),
    _inPainting(false),
    _nextFrameId(1),
    _maxInFlight(OSXRDP_DEFAULT_MAX_IN_FLIGHT),
    _inFlightHead(0),
    _inFlightCount(0)
{}

PaintManager::~PaintManager() {
    Release();
}

int PaintManager::CheckRecordFormat(const struct mod* mod) {
    assert(mod != NULL);
    if (mod == NULL) return -1;
    
    if (mod->client_info.gfx == 1) {
        if (mod->client_info.capture_code == CC_GFX_A2) {
            // using H.264
            return OSXRDP_RECORDFORMAT_NV12;
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
    assert(_recordShm == NULL);
    assert(_inited == false);
    
    if (_inited == true) {
        return false;
    }
    
    if (mod == NULL || recordFormat < 0) {
        // log
        return false;
    }
    
    char shm_name[512] = {0,};
    if (get_object_name(sessionId, OSXRDP_SCREENSHM_NAME, shm_name, sizeof(shm_name), isLockScreen) == 0) {
        // log
        return false;
    }
    
    // 녹화 데이터가 담긴 공유 메모리를 열기
    _recordShm = xshm_open(shm_name);
    if (_recordShm == NULL) {
        // log
        return false;
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
    
    if (recordFormat == OSXRDP_RECORDFORMAT_NV12) {
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
    _nextFrameId = 1;
    _maxInFlight = OSXRDP_DEFAULT_MAX_IN_FLIGHT;
    const char* maxInFlightEnv = getenv("OSXRDP_MAX_IN_FLIGHT");
    if (maxInFlightEnv != NULL && *maxInFlightEnv != '\0') {
        int maxInFlight = atoi(maxInFlightEnv);
        if (maxInFlight >= OSXRDP_MIN_MAX_IN_FLIGHT && maxInFlight <= OSXRDP_MAX_MAX_IN_FLIGHT) {
            _maxInFlight = maxInFlight;
        }
    }
    ResetInFlight();
    
    _inited = true;
    
    return true;
}

void PaintManager::Release() {
    if (_paint != NULL) {
        delete _paint;
        _paint = NULL;
    }
    
    // hack
    // xrdp 가 화면을 그리는 중에 (백그라운드 스레드에서) 공유 메모리를 무효화시키면 메모리가 깨져버리면서 crash 가 발생
    // 이는 잠금 화면 에이전트 -> 메인 에이전트로 재접속 시 발생하는 문제이며, xrdp 인코더의 상태를 직접적으로 알 수 없어 지금 방식으로는 고치기 어렵다.
    // 이를 근본적으로 해결하기 위해서는 공유 메모리를 각 에이전트별로 만들어 전환하는 방식에서 osxup 에서 만든 공유 메모리를 에이전트가 사용하도록 구조를 바꿔야 한다.
    // 임시적으로 xrdp 인코더 스레드가 공유 메모리에 담긴 데이터를 다 처리할 수 있도록 잠시 sleep 후 정리하도록 해서 크래시를 회피한다.
    sleep(2);
    
    // close shm
    if (_recordShm != NULL) {
        xshm_close(_recordShm);
        
        _recordShm = NULL;
    }
    
    if (_cursorShm != NULL) {
        xshm_close(_cursorShm);
        
        _cursorShm = NULL;
    }
    
    _nextFrameId = 1;
    ResetInFlight();
    _inPainting = false;
    _inited = false;
}

void PaintManager::Paint() {
    assert(_paint != NULL);
    assert(_recordShm != NULL);
    assert(_cursorShm != NULL);
    assert(_inited == true);
    
    // 마우스 커서 그리기
    PaintMouseCursor();
    
    if (_inFlightCount >= _maxInFlight) {
        return;
    }
    
    screenrecord_frame_t* frameInfo = NULL;
    char* imgData = NULL;
    size_t imgDataSize = 0;
    unsigned int shm_frame_id = 0;
    
    // 읽을 데이터가 있는지 확인
    if (GetPaintData(&frameInfo, &imgData, &imgDataSize, &shm_frame_id) == false) {
        return;
    }

    // xrdp의 ACK 윈도우는 작은 연속 frame_id를 가정한다.
    // SHM read_pos(큰 값/불연속) 대신 세션 로컬 frame_id를 사용한다.
    unsigned int frame_id = _nextFrameId++;
    if (_nextFrameId >= 0x7FFFFFFFU) {
        _nextFrameId = 1;
    }

    if (PushInFlight(frame_id, shm_frame_id) == false) {
        return;
    }
    _inPainting = (_inFlightCount > 0);
    
    // 그리기
    _paint->DoPaint(_mod, frameInfo, imgData, imgDataSize, frame_id);
}

bool PaintManager::GetPaintData(screenrecord_frame_t** outFrameInfo, char** outImgData, size_t* outImgDataSize, unsigned int* frame_id) {
    screenrecord_shm_t* shm = (screenrecord_shm_t*)_recordShm->mem;
    
    // 읽을 데이터가 있는지 확인
    unsigned int read_pos = atomic_load_explicit(&shm->read_pos,  memory_order_acquire);
    unsigned int write_pos = atomic_load_explicit(&shm->write_pos, memory_order_acquire);
    
    if (read_pos == write_pos) {
        return false;
    }
    
    int forceRedrawAll = 0;
    unsigned int targetPos = read_pos + (unsigned int)_inFlightCount;
    if (targetPos >= write_pos) {
        return false;
    }

    // backlog가 너무 큰 경우에만 최신 프레임으로 점프.
    // 단, 이미 in-flight가 있으면 순서를 깨지 않기 위해 점프하지 않는다.
    if (_inFlightCount == 0 && (write_pos - read_pos >= FRAME_SLOTS || read_pos == 0)) {
        targetPos = write_pos - 1;
        forceRedrawAll = 1;
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
    
    *frame_id = targetPos;
    
    //atomic_store_explicit(&shm->read_pos, read_pos + 1, memory_order_release);
    
    return true;
}

bool PaintManager::PushInFlight(unsigned int frameId, unsigned int shmReadPos) {
    if (_inFlightCount >= kInFlightCapacity) {
        return false;
    }

    int tail = (_inFlightHead + _inFlightCount) % kInFlightCapacity;
    _inFlightFrameIds[tail] = frameId;
    _inFlightReadPos[tail] = shmReadPos;
    _inFlightCount++;
    return true;
}

int PaintManager::PopAckedInFlight(int ackFrameId, unsigned int* outMaxReadPos) {
    int popped = 0;
    unsigned int maxReadPos = 0;
    bool hasMax = false;

    if (ackFrameId < 0) {
        while (_inFlightCount > 0) {
            int idx = _inFlightHead;
            maxReadPos = _inFlightReadPos[idx];
            hasMax = true;
            _inFlightHead = (_inFlightHead + 1) % kInFlightCapacity;
            _inFlightCount--;
            popped++;
        }
        if (hasMax && outMaxReadPos != NULL) {
            *outMaxReadPos = maxReadPos;
        }
        return popped;
    }

    while (_inFlightCount > 0) {
        int idx = _inFlightHead;
        unsigned int frontFrameId = _inFlightFrameIds[idx];
        if ((int)frontFrameId > ackFrameId) {
            break;
        }

        maxReadPos = _inFlightReadPos[idx];
        hasMax = true;
        _inFlightHead = (_inFlightHead + 1) % kInFlightCapacity;
        _inFlightCount--;
        popped++;
    }

    if (hasMax && outMaxReadPos != NULL) {
        *outMaxReadPos = maxReadPos;
    }
    return popped;
}

void PaintManager::ResetInFlight() {
    _inFlightHead = 0;
    _inFlightCount = 0;
}

void PaintManager::PaintEnd(int ackFrameId) {
    assert(_recordShm != NULL);
    assert(_inited == true);
    
    if (_inFlightCount <= 0) {
        _inPainting = false;
        return;
    }

    unsigned int maxReadPos = 0;
    int popped = PopAckedInFlight(ackFrameId, &maxReadPos);
    if (popped <= 0) {
        _inPainting = (_inFlightCount > 0);
        return;
    }

    screenrecord_shm_t* shm = (screenrecord_shm_t*)_recordShm->mem;
    unsigned int read_pos = atomic_load_explicit(&shm->read_pos, memory_order_relaxed);
    unsigned int nextReadPos = maxReadPos + 1;

    if (nextReadPos > read_pos) {
        atomic_store_explicit(&shm->read_pos, nextReadPos, memory_order_release);
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
