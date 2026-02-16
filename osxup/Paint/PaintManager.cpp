#include "../pch.h"
#include "../osxup.h"
#include "PaintManager.h"
#include "osxrdp/packet.h"
#include "PaintBitmap.h"
#include "PaintH264.h"
#include "utils.h"

static const char* OSXRDP_SCREENSHM_NAME = "/osxrdpshm";
static const char* OSXRDP_CURSORSHM_NAME = "/osxrdpcursorshm";

PaintManager::PaintManager() :
    _mod(NULL),
    _paint(NULL),
    _recordShm(NULL),
    _cursorShm(NULL)
{}

PaintManager::~PaintManager() {
    Release();
}

int PaintManager::CheckRecordFormat(const struct mod* mod) {
    assert(mod != NULL);
    if (mod == NULL) return -1;
    
    if (mod->client_info.gfx == 1) {
        if (mod->client_info.rfx_codec_id != 0) {
            // rfx with gfx currently not support.
            return -1;
        }
        
        // using H.264
        return OSXRDP_RECORDFORMAT_NV12;
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
    else {
        _paint = new PaintBitmap();
    }
    
    // painter initialize
    _paint->Initialize(mod);
    
    _mod = mod;
    
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
    
    _inited = false;
}

void PaintManager::Paint() {
    assert(_paint != NULL);
    assert(_recordShm != NULL);
    assert(_cursorShm != NULL);
    assert(_inited == true);
    
    // 마우스 커서 그리기
    PaintMouseCursor();
    
    screenrecord_frame_t* frameInfo = NULL;
    char* imgData = NULL;
    size_t imgDataSize = 0;
    unsigned int frame_id = 0;
    
    // 읽을 데이터가 있는지 확인
    if (GetPaintData(&frameInfo, &imgData, &imgDataSize, &frame_id) == false) {
        return;
    }
    
    // 그리기
    _paint->DoPaint(_mod, frameInfo, imgData, imgDataSize, frame_id);
}

bool PaintManager::GetPaintData(screenrecord_frame_t** outFrameInfo, char** outImgData, size_t* outImgDataSize, unsigned int* frame_id) {
    screenrecord_shm_t* shm = (screenrecord_shm_t*)_recordShm->mem;
    
    // 읽을 데이터가 있는지 확인
    unsigned int read_pos = atomic_load_explicit(&shm->read_pos,  memory_order_relaxed);
    unsigned int write_pos = atomic_load_explicit(&shm->write_pos, memory_order_acquire);
    
    if (read_pos == write_pos) {
        return false;
    }
    
    int forceRedrawAll = 0;
    if (write_pos - read_pos >= FRAME_SLOTS || read_pos == 0) {
        read_pos = write_pos - 1;
        forceRedrawAll = 1;
    }
    
    unsigned int idx = read_pos % FRAME_SLOTS;
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
    
    *frame_id = read_pos;
    
    atomic_store_explicit(&shm->read_pos, read_pos + 1, memory_order_release);
    
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
