#include <Accelerate/Accelerate.h>

#include "ScreenRecorderManager.h"
#include "osxrdp/packet.h"
#import "ScreenRecorderImpl.h"
#import "ScreenRecorderFallbackImpl.h"
#import "../VirtualMon/DisplayUtils.h"
#import <CoreMedia/CoreMedia.h>
#include "utils.h"

#define _ALIGN_DOWN_EVEN(v)   ((v) & ~1)
#define _ALIGN_UP_EVEN(v)     (((v) + 1) & ~1)

namespace {
inline void CopyRows(uint8_t* dst, const uint8_t* src, size_t rowBytes, size_t srcStride, size_t rows) {
    if (srcStride == rowBytes) {
        memcpy(dst, src, rowBytes * rows);
        return;
    }

    const uint8_t* srcRow = src;
    uint8_t* dstRow = dst;
    for (size_t row = 0; row < rows; ++row) {
        memcpy(dstRow, srcRow, rowBytes);
        srcRow += srcStride;
        dstRow += rowBytes;
    }
}

inline int GetDisplayPointSize(int pixelSize, bool isRetina) {
    if (isRetina == false) {
        return pixelSize;
    }

    return pixelSize / 2;
}
}

ScreenRecorderManager::ScreenRecorderManager(bool useLegacyRecorder) :
    _cursorShm(NULL),
    _client(NULL),
    _rfxCanonical(NULL),
    _rfxCanonicalSize(0),
    _rfxCanonicalWidth(0),
    _rfxCanonicalHeight(0),
    _rfxTileCols(0),
    _rfxTileRows(0),
    _rfxFullRedrawRequired(true),
    _recorderCnt(0),
    _useLegacyRecorder(useLegacyRecorder),
    _recordShmCnt(0)
{
    memset(_recordShm, 0x00, sizeof(_recordShm));
    ResetPendingDirty();
}

ScreenRecorderManager::~ScreenRecorderManager() {
    Stop();

    ReleaseRFXCanonical();
}

bool ScreenRecorderManager::StartRecord(xstream_t* cmd) {
    memset(&_recordParams, 0x00, sizeof(struct RecordStartParams));
    
    if (ParseStartRecordParams(cmd, &_recordParams) == false) {
        return false;
    }

    if (ResolveDisplayForRecorder() == false) {
        return false;
    }

    if (PrepareRecordResources() == false) {
        return false;
    }
    
    for (int i = 0; i < _recordParams.monitorCount; i++) {
        id<IScreenRecorder> impl = nil;
        
        if (_useLegacyRecorder == false) {
            impl = [[ScreenRecorderImpl alloc] init];
        }
        else {
            impl = [[ScreenRecorderFallbackImpl alloc] init];
        }
        
        on_record_data recordDataCb = HandleBGRA32RecordData;
        if (_recordParams.recordFormat == OSXRDP_RECORDFORMAT_NV12_PACKED) {
            recordDataCb = HandleNV12PackedRecordData;
        }
        else if (_recordParams.recordFormat == OSXRDP_RECORDFORMAT_NV12_ALIGNED) {
            recordDataCb = HandleNV12AlignedRecordData;
        }
        else if (_recordParams.recordFormat == OSXRDP_RECORDFORMAT_RFX) {
            recordDataCb = HandleRFXRecordData;
        }

        int outputIndex = _recordParams.monitorInfo[i].outputIndex;
        int recordWidth = GetMonitorRecordWidth(i);
        int recordHeight = GetMonitorRecordHeight(i);
        
        [impl initializeWithDisplayId:_recordParams.monitorInfo[i].displayId
                    DisplayIndex:outputIndex
                    RecordWidth:recordWidth RecordHeight:recordHeight
                    RecordFramerate:_recordParams.framerate RecordFormat:_recordParams.recordFormat
                    RecordDataCallback:recordDataCb RecordDataCallbackUserData:this
                    RecordCmdCallback:HandleRecordCommand RecordCmdCallbackUserData:this];

        if ([impl start] == NO) {
            DestroyRecordShm();
            DestroyCursorShm();
            return false;
        }
        
        _recorder[_recorderCnt] = (__bridge_retained void*)impl;
        _recorderCnt++;
    }

    return true;
}

bool ScreenRecorderManager::ParseStartRecordParams(xstream_t* cmd, RecordStartParams* params) {
    if (cmd == NULL || params == NULL) {
        return false;
    }

    params->monitorIndex = xstream_readInt32(cmd);
    params->width = xstream_readInt32(cmd);
    params->height = xstream_readInt32(cmd);
    params->framerate = xstream_readInt32(cmd);
    params->recordFormat = xstream_readInt32(cmd);
    params->useVirtualMon = xstream_readInt32(cmd);
    params->monitorCount = xstream_readInt32(cmd);

    if (params->monitorCount > 16) params->monitorCount = 1;
    int requestedMonitorCount = params->monitorCount;
    RecordStartParams::MONITOR_INFO requestedMonitorInfo[16];
    memset(requestedMonitorInfo, 0x00, sizeof(requestedMonitorInfo));
    
    for (int i = 0; i < params->monitorCount; i++) {
        requestedMonitorInfo[i].left = xstream_readInt32(cmd);
        requestedMonitorInfo[i].top = xstream_readInt32(cmd);
        requestedMonitorInfo[i].right = xstream_readInt32(cmd);
        requestedMonitorInfo[i].bottom = xstream_readInt32(cmd);
        requestedMonitorInfo[i].is_primary = xstream_readInt32(cmd);
        requestedMonitorInfo[i].outputIndex = i;
    }

    // 잠금화면의 경우 virtual monitor 를 지원하지 않음.
    if (is_root_process() != 0) {
        params->useVirtualMon = 0;
        params->framerate = 30;
    }
    else {
        if (params->recordFormat == OSXRDP_RECORDFORMAT_NV12_ALIGNED) {
            params->framerate = 60;
        }
        else if (params->recordFormat == OSXRDP_RECORDFORMAT_NV12_PACKED) {
            params->framerate = 60;
        }
        else {
            params->framerate = 30;
        }
    }
    
    bool forceSingleMonitor = (params->useVirtualMon == 0 || params->recordFormat != OSXRDP_RECORDFORMAT_NV12_PACKED);
    if (forceSingleMonitor == true) {
        int monitorIndex = 0;
        for (int i = 0; i < requestedMonitorCount; i++) {
            if (requestedMonitorInfo[i].is_primary != 0) {
                monitorIndex = i;
                break;
            }
        }

        params->monitorInfo[0] = requestedMonitorInfo[monitorIndex];
        params->monitorInfo[0].outputIndex = monitorIndex;
        params->monitorCount = 1;
    }
    else {
        for (int i = 0; i < requestedMonitorCount; i++) {
            params->monitorInfo[i] = requestedMonitorInfo[i];
        }
    }

    if (params->width <= 0 || params->height <= 0) {
        NSLog(@"[ScreenRecorderManager::StartRecord] invalid request. width: %d height: %d", params->width, params->height);
        return false;
    }

    if (params->width > 10000 || params->height > 10000) {
        NSLog(@"[ScreenRecorderManager::StartRecord] invalid request. too large display width: %d height: %d", params->width, params->height);
        return false;
    }

    params->width &= ~0x1;
    params->height &= ~0x1;

    // 절전 모드는 아니지만, 디스플레이가 꺼져 있는 경우 문제가 발생할 수 있음.
    // 따라서 먼저 디스플레이를 잠시 깨워준다. (가상 디스플레이 사용중일때는 다시 꺼질 예정)
    VirtualMonitor::WakeupDisplay();

    return true;
}

bool ScreenRecorderManager::PrepareRecordResources() {
    
    for (int i = 0; i < _recordParams.monitorCount; i++) {
        if (CreateRecordShm(i) == false) {
            NSLog(@"[ScreenRecorderManager::StartRecord] could not create record shm");
            return false;
        }
    }
    
    if (CreateCursorShm() == false) {
        NSLog(@"[ScreenRecorderManager::StartRecord] could not create cursor shm");
        DestroyRecordShm();
        return false;
    }

    // 세션 시작 시 canonical 은 반드시 무효화 (이전 세션 잔상 방지)
    InvalidateRFXCanonical();
    ResetPendingDirty();

    return true;
}

bool ScreenRecorderManager::ResolveDisplayForRecorder() {

    if (_recordParams.useVirtualMon == 0) {
        _recordParams.monitorInfo[0].displayId = (int)CGMainDisplayID();
        
        CGRect rect = CGDisplayBounds(_recordParams.monitorInfo[0].displayId);
        
        _inputHandler.UpdateDisplayRes((int)rect.size.width, (int)rect.size.height, GetMonitorRecordWidth(0), GetMonitorRecordHeight(0));
        _inputHandler.ResetDisplayLayout();
        _inputHandler.AddDisplayLayout(_recordParams.monitorInfo[0].left, _recordParams.monitorInfo[0].top,
                                       GetMonitorRecordWidth(0), GetMonitorRecordHeight(0),
                                       (int)rect.origin.x, (int)rect.origin.y,
                                       (int)rect.size.width, (int)rect.size.height,
                                       _recordParams.monitorInfo[0].displayId);
        
        return true;
    }
    
    _inputHandler.UpdateDisplayRes(_recordParams.width, _recordParams.height, _recordParams.width, _recordParams.height);
    _inputHandler.ResetDisplayLayout();

    int primaryLeft = 0;
    int primaryTop = 0;
    for (int i = 0; i < _recordParams.monitorCount; i++) {
        if (_recordParams.monitorInfo[i].is_primary != 0) {
            primaryLeft = _recordParams.monitorInfo[i].left;
            primaryTop = _recordParams.monitorInfo[i].top;
            break;
        }
    }

    for (int i = 0; i < _recordParams.monitorCount; i++) {
        // todo : 성공,실패 판별

        int monitorWidth = GetMonitorRecordWidth(i);
        int monitorHeight = GetMonitorRecordHeight(i);
        int displayOriginX = _recordParams.monitorInfo[i].left - primaryLeft;
        int displayOriginY = _recordParams.monitorInfo[i].top - primaryTop;

        _virtualMonitor.Create(monitorWidth, monitorHeight, _recordParams.monitorInfo[i].left, _recordParams.monitorInfo[i].top, _recordParams.monitorInfo[i].outputIndex, _recordParams.monitorInfo[i].is_primary != 0);

        _recordParams.monitorInfo[i].displayId = _virtualMonitor.GetDisplayId(i);

        bool isRetina = _virtualMonitor.IsRetina(i);
        int displayWidth = GetDisplayPointSize(monitorWidth, isRetina);
        int displayHeight = GetDisplayPointSize(monitorHeight, isRetina);

        _inputHandler.AddDisplayLayout(_recordParams.monitorInfo[i].left, _recordParams.monitorInfo[i].top,
                                       monitorWidth, monitorHeight,
                                       displayOriginX, displayOriginY,
                                       displayWidth, displayHeight,
                                       _recordParams.monitorInfo[i].displayId);
    }

    _virtualMonitor.StartMonitor();

    return true;
}

int ScreenRecorderManager::GetMonitorRecordWidth(int recordIdx) {
    if (recordIdx < 0 || recordIdx >= 16) {
        return 0;
    }
    
    int width = _recordParams.monitorInfo[recordIdx].right - _recordParams.monitorInfo[recordIdx].left;
    
    // xrdp 의 실제 monitor rect 는 right/bottom inclusive 이다.
    // osxup 이 단일 모니터용으로 보낸 synthetic rect(right=width)는 그대로 둔다.
    if (!(_recordParams.monitorCount == 1 &&
          _recordParams.monitorInfo[recordIdx].left == 0 &&
          _recordParams.monitorInfo[recordIdx].right == _recordParams.width)) {
        width++;
    }
    
    return _ALIGN_DOWN_EVEN(width);
}

int ScreenRecorderManager::GetMonitorRecordHeight(int recordIdx) {
    if (recordIdx < 0 || recordIdx >= 16) {
        return 0;
    }
    
    int height = _recordParams.monitorInfo[recordIdx].bottom - _recordParams.monitorInfo[recordIdx].top;
    
    // xrdp 의 실제 monitor rect 는 right/bottom inclusive 이다.
    // osxup 이 단일 모니터용으로 보낸 synthetic rect(bottom=height)는 그대로 둔다.
    if (!(_recordParams.monitorCount == 1 &&
          _recordParams.monitorInfo[recordIdx].top == 0 &&
          _recordParams.monitorInfo[recordIdx].bottom == _recordParams.height)) {
        height++;
    }
    
    return _ALIGN_DOWN_EVEN(height);
}

bool ScreenRecorderManager::CreateRecordShm(int recordIdx) {
    if (recordIdx < 0 || recordIdx >= 16) return false;

    const int outputIndex = _recordParams.monitorInfo[recordIdx].outputIndex;
    if (outputIndex < 0 || outputIndex >= 16) return false;
    if (_recordShm[outputIndex] != NULL) return false;

    const int width = GetMonitorRecordWidth(recordIdx);
    const int height = GetMonitorRecordHeight(recordIdx);

    // todo : format 마다 정확한 크기 설정하기
    int rawDataSize = width * height * 5 + (sizeof(size_t) * 2);
    
    char shm_name[512];
    if (get_object_name_by_sessionid("/osxrdpshm", shm_name, 512, is_root_process()) == 0) {
        return false;
    }
    
    char shm_name_with_idx[512];
    snprintf(shm_name_with_idx, sizeof(shm_name_with_idx), "%s_%d", shm_name, outputIndex);

    _recordShm[outputIndex] = xshm_create(shm_name_with_idx, sizeof(screenrecord_shm_t) + (rawDataSize * FRAME_SLOTS));
    if (_recordShm[outputIndex] == NULL) {
        NSLog(@"[ScreenRecorderManager::CreateRecordShm] xshm_create failed. outputIndex = %d", outputIndex);
        
        return false;
    }
    
    memset(_recordShm[outputIndex]->mem, 0x00, sizeof(screenrecord_shm_t) + (rawDataSize * FRAME_SLOTS));
    
    screenrecord_shm_t* shm = (screenrecord_shm_t*)_recordShm[outputIndex]->mem;
    shm->width = width;
    shm->height = height;
    shm->fps = 60;
    shm->screenrecord_data_size = rawDataSize;
    
    _recordShmCnt++;
    
    return true;
}

void ScreenRecorderManager::DestroyRecordShm() {
    for (int i = 0; i < 16; i++) {
        if (_recordShm[i] != NULL) {
            xshm_close(_recordShm[i]);
            xshm_destroy(_recordShm[i]);
            _recordShm[i] = NULL;
        }
    }
    
    _recordShmCnt = 0;
}

bool ScreenRecorderManager::CreateCursorShm() {
    if (_cursorShm != NULL) {
        NSLog(@"[ScreenRecorderManager::CreateCursorShm] cursorShm is already exists.");
        
        return false;
    }
    
    char shm_name[512];
    if (get_object_name_by_sessionid("/osxrdpcursorshm", shm_name, 512, is_root_process()) == 0) {
        return false;
    }

    _cursorShm = xshm_create(shm_name, sizeof(cursor_data_t));
    if (_cursorShm == NULL) {
        NSLog(@"[ScreenRecorderManager::CreateCursorShm] xshm_create failed.");
        
        return false;
    }
    
    memset(_cursorShm->mem, 0x00, sizeof(cursor_data_t));
    
    // init cursor mask
    cursor_data_t* cursor_data = (cursor_data_t*)_cursorShm->mem;
    memset(cursor_data->cursorMaskData, 0xFF, MAX_CURSOR_IMG_BUFFER_SIZE);
    
    return true;
}

void ScreenRecorderManager::DestroyCursorShm() {
    if (_cursorShm == NULL) {
        return;
    }
    
    xshm_close(_cursorShm);
    xshm_destroy(_cursorShm);
    _cursorShm = NULL;
}

void ScreenRecorderManager::Stop() {
    // 화면 녹화를 먼저 정지
    for (int i = 0; i < _recorderCnt; i++) {
        id<IScreenRecorder> impl = (__bridge id<IScreenRecorder>)_recorder[i];
        if ([impl stop] == NO) {
            // 정지 실패 (간혹 빠르게 호출하면 이럼)
            sleep(1);
            
            // 재시도
            [impl stop];
        }
        
        CFRelease(_recorder[i]);
    }
    
    _recorderCnt = 0;
    memset(_recorder, 0x00, sizeof(_recorder));
    
    _virtualMonitor.Destroy();

    // 공유 메모리 정리
    DestroyRecordShm();
    DestroyCursorShm();

    ReleaseRFXCanonical();
    ResetPendingDirty();
}

void ScreenRecorderManager::HandleCommand(xipc_t* client, xstream_t* cmd) {
    if (cmd == NULL) return;
    
    int packetType = xstream_readInt32(cmd);
    switch (packetType) {
        case OSXRDP_PACKETTYPE_REQ_SCREEN: {
            _client = client;
            bool re = StartRecord(cmd);
            
            NSLog(@"[ScreenRecorderManager::HandleCommand] start record. result %d", re);

            xstream* result = xstream_create(32);
            if (result != NULL) {
                xstream_writeInt32(result, OSXRDP_CMDTYPE_SCREEN);
                xstream_writeInt32(result, OSXRDP_PACKETTYPE_REP_SCREEN);
                xstream_writeInt32(result, re ? 1 : 0);
                
                int rawBufferLen = 0;
                const void* rawBuffer = xstream_get_raw_buffer(result, &rawBufferLen);
                
                xipc_send_data(client, rawBuffer, rawBufferLen);
                
                xstream_free(result);
            }
            
            break;
        }
        case OSXRDP_PACKETTYPE_REQ_SCREENOFF: {
            NSLog(@"[ScreenRecorderManager::HandleCommand] stop record");
            
            Stop();
            break;
        }
        case OSXRDP_PACKETTYPE_MOUSEEVT: {
            _inputHandler.HandleMousseInputEvent(cmd);

            if (_cursorShm != NULL && _cursorShm->mem != NULL) {
                _cursorHandler.HandleCursorInfo((cursor_data_t*)_cursorShm->mem);
            }
            break;
        }
        case OSXRDP_PACKETTYPE_KEYBOARDEVT: {
            _inputHandler.HandleKeyboardInputEvent(cmd);
            break;
        }
    }
}

void ScreenRecorderManager::SendDisconnectMsgToClient() {
    struct stop_msg {
        int cmdType;
        int packetType;
    };
    
    // 가상 모니터를 먼저 파괴 (todo : 정확한 정리 타이밍을 다시 정하기)
    // 2개 이상의 클라이언트가 겹치면 충돌나서 원본 물리 화면이 안나오는 경우가 발생.
    //_virtualMonitor.Destroy();
    
    struct stop_msg msg = { OSXRDP_CMDTYPE_MSGFROMAGENT, OSXRDP_PACKETTYPE_TERMINATE };
    if (_client != NULL) {
        xipc_send_data(_client, &msg, sizeof(msg));
    }
}

bool ScreenRecorderManager::AcquireFrameSlot(screenrecord_shm_t** recordInfoOut, screenrecord_frame** frameOut, char** dataOut, unsigned int* writePosOut, int displayIdx) {
    if (displayIdx < 0 || displayIdx >= 16) {
        return false;
    }

    if (_recordShm[displayIdx] == NULL || _recordShm[displayIdx]->mem == NULL) {
        return false;
    }

    if (recordInfoOut == NULL || frameOut == NULL || dataOut == NULL || writePosOut == NULL) {
        return false;
    }

    screenrecord_shm_t* recordInfo = (screenrecord_shm_t*)_recordShm[displayIdx]->mem;
    unsigned int readPos = atomic_load_explicit(&recordInfo->read_pos, memory_order_acquire);
    unsigned int writePos = atomic_load_explicit(&recordInfo->write_pos, memory_order_relaxed);

    // 아직 소비하지 못한 데이터가 너무 많은 경우 버리기 (drop)
    if (writePos - readPos >= FRAME_SLOTS) {
        return false;
    }

    int index = writePos % FRAME_SLOTS;
    *recordInfoOut = recordInfo;
    *frameOut = &recordInfo->frames[index];
    *dataOut = recordInfo->screenrecord_datas + (recordInfo->screenrecord_data_size * index);
    *writePosOut = writePos;

    return true;
}

void ScreenRecorderManager::CommitFrameSlot(screenrecord_shm_t* recordInfo, unsigned int writePos, int displayIdx) {
    if (recordInfo == NULL) {
        return;
    }

    atomic_store_explicit(&recordInfo->write_pos, writePos + 1, memory_order_release);

    union needPaintMsg {
        struct {
            int packetType;
            int displayIdx;
        } _unused;
        long dummy;
    } paintMsg {
        OSXRDP_CMDTYPE_NEEDPAINT,
        displayIdx
    };
    
    xipc_send_data(_client, (void*)&paintMsg.dummy, sizeof(paintMsg.dummy));
}

bool ScreenRecorderManager::CopyNV12PackedFrame(void* imageBufferRef, char* screenrecord_data, int* widthOut, int* heightOut) {
    if (imageBufferRef == NULL || screenrecord_data == NULL || widthOut == NULL || heightOut == NULL) {
        return false;
    }

    CVImageBufferRef imageBuffer = (CVImageBufferRef)imageBufferRef;
    size_t width = CVPixelBufferGetWidth(imageBuffer);
    size_t height = CVPixelBufferGetHeight(imageBuffer);
    if (width == 0 || height == 0) {
        return false;
    }

    uint8_t* ySrcBase = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0);
    uint8_t* uvSrcBase = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 1);
    if (ySrcBase == NULL || uvSrcBase == NULL) {
        return false;
    }

    size_t yStride = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0);
    size_t uvStride = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 1);
    const size_t rowBytes = width;
    const size_t uvHeight = height / 2;
    size_t packedImgSize = (width * height) + (width * uvHeight);

    memcpy(screenrecord_data, &packedImgSize, sizeof(size_t));
    uint8_t* dstData = (uint8_t*)(screenrecord_data + sizeof(size_t));
    CopyRows(dstData, ySrcBase, rowBytes, yStride, height);

    uint8_t* dstUV = dstData + (width * height);
    CopyRows(dstUV, uvSrcBase, rowBytes, uvStride, uvHeight);

    *widthOut = (int)width;
    *heightOut = (int)height;
    return true;
}

bool ScreenRecorderManager::CopyNV12AlignedFrame(void* imageBufferRef, char* screenrecord_data, int* widthOut, int* heightOut) {
    if (imageBufferRef == NULL || screenrecord_data == NULL || widthOut == NULL || heightOut == NULL) {
        return false;
    }
    
    CVImageBufferRef imageBuffer = (CVImageBufferRef)imageBufferRef;
    size_t width = CVPixelBufferGetWidth(imageBuffer);
    size_t height = CVPixelBufferGetHeight(imageBuffer);
    if (width == 0 || height == 0) {
        return false;
    }
    
    uint8_t* ySrcBase = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0);
    uint8_t* uvSrcBase = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 1);
    if (ySrcBase == NULL || uvSrcBase == NULL) {
        return false;
    }
    
    size_t yStride = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0);
    size_t uvStride = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 1);
    const size_t uvHeight = height / 2;
    
    size_t alignedImgSize = (yStride * height) + (uvStride * uvHeight) + sizeof(size_t); // stride value hack
    
    memcpy(screenrecord_data, &alignedImgSize, sizeof(size_t));
    
    // hack (to pass stride value to xrdp vtoolbox encorder)
    memcpy((uint8_t*)screenrecord_data + sizeof(size_t), &yStride, sizeof(size_t));
    
    uint8_t* dstData = (uint8_t*)(screenrecord_data + (sizeof(size_t) * 2));
    memcpy(dstData, ySrcBase, yStride * height);
    
    uint8_t* dstUV = dstData + (yStride * height);
    memcpy(dstUV, uvSrcBase, uvStride * uvHeight);

    *widthOut = (int)width;
    *heightOut = (int)height;
    
    return true;
}

bool ScreenRecorderManager::CopyBGRA32Frame(void* imageBufferRef, char* screenrecord_data, int* widthOut, int* heightOut) {
    if (imageBufferRef == NULL || screenrecord_data == NULL || widthOut == NULL || heightOut == NULL) {
        return false;
    }

    CVImageBufferRef imageBuffer = (CVImageBufferRef)imageBufferRef;
    size_t width = CVPixelBufferGetWidth(imageBuffer);
    size_t height = CVPixelBufferGetHeight(imageBuffer);
    if (width == 0 || height == 0) {
        return false;
    }

    uint8_t* rawImageBuffer = (uint8_t*)CVPixelBufferGetBaseAddress(imageBuffer);
    if (rawImageBuffer == NULL) {
        return false;
    }

    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
    size_t rowSize = width * 4;
    size_t imgSize = rowSize * height;

    memcpy(screenrecord_data, &imgSize, sizeof(size_t));
    uint8_t* dest = (uint8_t*)screenrecord_data + sizeof(size_t);
    CopyRows(dest, rawImageBuffer, rowSize, bytesPerRow, height);

    *widthOut = (int)width;
    *heightOut = (int)height;
    return true;
}

void ScreenRecorderManager::PopulateDirtyRectsFromSampleBuffer(void* sampleBufferRef, int width, int height, screenrecord_frame* current_frame) {
    if (current_frame == NULL) {
        return;
    }

    current_frame->dirtyCount = 0;

    CMSampleBufferRef sampleBuffer = (CMSampleBufferRef)sampleBufferRef;
    if (sampleBuffer == NULL) {
        return;
    }

    CFArrayRef arr = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (arr == NULL || CFArrayGetCount(arr) == 0) {
        return;
    }

    CFDictionaryRef att = (CFDictionaryRef)CFArrayGetValueAtIndex(arr, 0);
    if (att == NULL) {
        return;
    }

    CFArrayRef dirtyArr = (CFArrayRef)CFDictionaryGetValue(att, (__bridge CFStringRef)SCStreamFrameInfoDirtyRects);
    if (dirtyArr == NULL) {
        return;
    }

    current_frame->dirtyCount = (int)CFArrayGetCount(dirtyArr);
    if (current_frame->dirtyCount < 0 || current_frame->dirtyCount > MAX_DIRTY_COUNT) {
        current_frame->dirtyCount = 0;
        return;
    }

    CGRect tmp;
    for (int i = 0; i < current_frame->dirtyCount; i++) {
        CFTypeRef element = CFArrayGetValueAtIndex(dirtyArr, i);
        CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)element, &tmp);
        ProcessDirtyArea(&tmp, width, height, &(current_frame->dirtys[i]));
    }
}

void ScreenRecorderManager::PopulateDirtyRectsFromArray(const CGRect* dirtyRects, int dirtyRectsCnt, int width, int height, screenrecord_frame* current_frame) {
    if (current_frame == NULL) {
        return;
    }

    current_frame->dirtyCount = 0;
    if (dirtyRects == NULL || dirtyRectsCnt <= 0) {
        return;
    }

    current_frame->dirtyCount = dirtyRectsCnt;
    if (current_frame->dirtyCount > MAX_DIRTY_COUNT) {
        current_frame->dirtyCount = 0;
        return;
    }

    for (int i = 0; i < current_frame->dirtyCount; i++) {
        ProcessDirtyArea(&dirtyRects[i], width, height, &(current_frame->dirtys[i]));
    }
}

void ScreenRecorderManager::ResetPendingDirty() {
    memset(_pendingDirty, 0x00, sizeof(_pendingDirty));
    memset(_pendingDirtyFull, 0x00, sizeof(_pendingDirtyFull));
}

void ScreenRecorderManager::ResetPendingDirty(int displayIdx) {
    if (displayIdx < 0 || displayIdx >= 16) {
        return;
    }

    memset(&_pendingDirty[displayIdx], 0x00, sizeof(_pendingDirty[displayIdx]));
    _pendingDirtyFull[displayIdx] = false;
}

void ScreenRecorderManager::AddPendingDirty(int displayIdx, const CGRect* dirtyRects, int dirtyRectsCnt, int width, int height) {
    if (displayIdx < 0 || displayIdx >= 16) {
        return;
    }

    if (_pendingDirtyFull[displayIdx] == true) {
        return;
    }

    if (dirtyRects == NULL || dirtyRectsCnt <= 0 || dirtyRectsCnt > MAX_DIRTY_COUNT) {
        _pendingDirty[displayIdx].dirtyCount = 0;
        _pendingDirtyFull[displayIdx] = true;
        return;
    }

    if (_pendingDirty[displayIdx].dirtyCount + dirtyRectsCnt > MAX_DIRTY_COUNT) {
        _pendingDirty[displayIdx].dirtyCount = 0;
        _pendingDirtyFull[displayIdx] = true;
        return;
    }

    CGRect tmp;
    for (int i = 0; i < dirtyRectsCnt; i++) {
        int index = _pendingDirty[displayIdx].dirtyCount++;
        memcpy(&tmp, &dirtyRects[i], sizeof(CGRect));
        ProcessDirtyArea(&tmp, width, height, &_pendingDirty[displayIdx].dirtys[index]);
    }
}

void ScreenRecorderManager::AddPendingDirtyFromPixelBuffer(int displayIdx, void* pixelBuffer, const CGRect* dirtyRects, int dirtyRectsCnt) {
    if (pixelBuffer == NULL) {
        return;
    }

    CVImageBufferRef imageBuffer = (CVImageBufferRef)pixelBuffer;
    int width = (int)CVPixelBufferGetWidth(imageBuffer);
    int height = (int)CVPixelBufferGetHeight(imageBuffer);
    if (width <= 0 || height <= 0) {
        return;
    }

    AddPendingDirty(displayIdx, dirtyRects, dirtyRectsCnt, width, height);
}

void ScreenRecorderManager::ApplyPendingDirty(int displayIdx, screenrecord_frame* current_frame) {
    if (displayIdx < 0 || displayIdx >= 16 || current_frame == NULL) {
        return;
    }

    if (_pendingDirtyFull[displayIdx] == true || current_frame->dirtyCount == 0) {
        current_frame->dirtyCount = 0;
        return;
    }

    int pendingCount = _pendingDirty[displayIdx].dirtyCount;
    if (pendingCount <= 0) {
        return;
    }

    if (current_frame->dirtyCount + pendingCount > MAX_DIRTY_COUNT) {
        current_frame->dirtyCount = 0;
        return;
    }

    memcpy(&current_frame->dirtys[current_frame->dirtyCount],
           _pendingDirty[displayIdx].dirtys,
           sizeof(struct RECT) * pendingCount);
    current_frame->dirtyCount += pendingCount;
}

void ScreenRecorderManager::HandleNV12PackedRecordData(void* pixelBuffer, const CGRect* dirtyRects, int dirtyRectsCnt, void* userData, int displayIdx){
    if (pixelBuffer == NULL || userData == NULL) return;

    ScreenRecorderManager* recorder = (ScreenRecorderManager*)userData;

    screenrecord_shm_t* recordInfo = NULL;
    screenrecord_frame* slot = NULL;
    char* screenrecord_data = NULL;
    unsigned int writePos = 0;
    if (recorder->AcquireFrameSlot(&recordInfo, &slot, &screenrecord_data, &writePos, displayIdx) == false) {
        recorder->AddPendingDirtyFromPixelBuffer(displayIdx, pixelBuffer, dirtyRects, dirtyRectsCnt);
        return;
    }

    HandleNV12PackedDirtyArea(pixelBuffer, slot, dirtyRects, dirtyRectsCnt, screenrecord_data);
    recorder->ApplyPendingDirty(displayIdx, slot);
    recorder->CommitFrameSlot(recordInfo, writePos, displayIdx);
    recorder->ResetPendingDirty(displayIdx);
}

void ScreenRecorderManager::HandleNV12AlignedRecordData(void* pixelBuffer, const CGRect* dirtyRects, int dirtyRectsCnt, void* userData, int displayIdx){
    if (pixelBuffer == NULL || userData == NULL) return;

    ScreenRecorderManager* recorder = (ScreenRecorderManager*)userData;

    screenrecord_shm_t* recordInfo = NULL;
    screenrecord_frame* slot = NULL;
    char* screenrecord_data = NULL;
    unsigned int writePos = 0;
    if (recorder->AcquireFrameSlot(&recordInfo, &slot, &screenrecord_data, &writePos, displayIdx) == false) {
        recorder->AddPendingDirtyFromPixelBuffer(displayIdx, pixelBuffer, dirtyRects, dirtyRectsCnt);
        return;
    }

    HandleNV12AlignedDirtyArea(pixelBuffer, slot, dirtyRects, dirtyRectsCnt, screenrecord_data);
    recorder->ApplyPendingDirty(displayIdx, slot);
    recorder->CommitFrameSlot(recordInfo, writePos, displayIdx);
    recorder->ResetPendingDirty(displayIdx);
}

void ScreenRecorderManager::HandleNV12PackedDirtyArea(void* pixelBuffer, screenrecord_frame* current_frame, const CGRect* dirtyRects, int dirtyRectsCnt, char* screenrecord_data) {
    int width = 0;
    int height = 0;
    if (CopyNV12PackedFrame(pixelBuffer, screenrecord_data, &width, &height) == false) {
        return;
    }

    PopulateDirtyRectsFromArray(dirtyRects, dirtyRectsCnt, width, height, current_frame);
}

void ScreenRecorderManager::HandleNV12AlignedDirtyArea(void* pixelBuffer, screenrecord_frame* current_frame, const CGRect* dirtyRects, int dirtyRectsCnt, char* screenrecord_data) {
    int width = 0;
    int height = 0;
    if (CopyNV12AlignedFrame(pixelBuffer, screenrecord_data, &width, &height) == false) {
        return;
    }

    PopulateDirtyRectsFromArray(dirtyRects, dirtyRectsCnt, width, height, current_frame);
}

void ScreenRecorderManager::HandleBGRA32RecordData(void* pixelBuffer, const CGRect* dirtyRects, int dirtyRectsCnt, void* userData, int displayIdx){
    if (pixelBuffer == NULL || userData == NULL) return;

    ScreenRecorderManager* recorder = (ScreenRecorderManager*)userData;

    screenrecord_shm_t* recordInfo = NULL;
    screenrecord_frame* slot = NULL;
    char* screenrecord_data = NULL;
    unsigned int writePos = 0;
    if (recorder->AcquireFrameSlot(&recordInfo, &slot, &screenrecord_data, &writePos, displayIdx) == false) {
        recorder->AddPendingDirtyFromPixelBuffer(displayIdx, pixelBuffer, dirtyRects, dirtyRectsCnt);
        return;
    }

    HandleBGRA32DirtyArea(pixelBuffer, slot, dirtyRects, dirtyRectsCnt, screenrecord_data);
    recorder->ApplyPendingDirty(displayIdx, slot);
    recorder->CommitFrameSlot(recordInfo, writePos, displayIdx);
    recorder->ResetPendingDirty(displayIdx);
}

void ScreenRecorderManager::HandleRFXRecordData(void* pixelBuffer, const CGRect* dirtyRects, int dirtyRectsCnt, void* userData, int displayIdx){
    if (pixelBuffer == NULL || userData == NULL) return;

    ScreenRecorderManager* recorder = (ScreenRecorderManager*)userData;

    screenrecord_shm_t* recordInfo = NULL;
    screenrecord_frame* slot = NULL;
    char* screenrecord_data = NULL;
    unsigned int writePos = 0;
    if (recorder->AcquireFrameSlot(&recordInfo, &slot, &screenrecord_data, &writePos, displayIdx) == false) {
        recorder->AddPendingDirtyFromPixelBuffer(displayIdx, pixelBuffer, dirtyRects, dirtyRectsCnt);
        return;
    }

    // osxup 가 full redraw 가 필요하다는 요청을 할 경우 이번 프레임은 강제로 full redraw 하도록 설정
    int wantFull = atomic_exchange_explicit(&recordInfo->consumer_request_full, 0, memory_order_acquire);
    if (wantFull != 0) {
        recorder->InvalidateRFXCanonical();
    }

    if (recorder->HandleRFXDirtyArea(pixelBuffer, slot, dirtyRects, dirtyRectsCnt, screenrecord_data, displayIdx) == false) {
        recorder->InvalidateRFXCanonical();
        return;
    }
    recorder->CommitFrameSlot(recordInfo, writePos, displayIdx);
    recorder->ResetPendingDirty(displayIdx);
}

void ScreenRecorderManager::HandleBGRA32DirtyArea(void* pixelBuffer, screenrecord_frame* current_frame, const CGRect* dirtyRects, int dirtyRectsCnt, char* screenrecord_data) {
    int width = 0;
    int height = 0;
    if (CopyBGRA32Frame(pixelBuffer, screenrecord_data, &width, &height) == false) {
        return;
    }

    PopulateDirtyRectsFromArray(dirtyRects, dirtyRectsCnt, width, height, current_frame);
}

bool ScreenRecorderManager::HandleRFXDirtyArea(void* pixelBuffer, screenrecord_frame* current_frame, const CGRect* dirtyRects, int dirtyRectsCnt, char* screenrecord_data, int displayIdx) {
    if (pixelBuffer == NULL || current_frame == NULL || screenrecord_data == NULL) {
        return false;
    }

    CVImageBufferRef imageBuffer = (CVImageBufferRef)pixelBuffer;
    size_t width = CVPixelBufferGetWidth(imageBuffer);
    size_t height = CVPixelBufferGetHeight(imageBuffer);
    if (width == 0 || height == 0) {
        return false;
    }

    if (CVPixelBufferGetPixelFormatType(imageBuffer) != kCVPixelFormatType_32BGRA) {
        return false;
    }

    uint8_t* srcBase = (uint8_t*)CVPixelBufferGetBaseAddress(imageBuffer);
    size_t srcStride = CVPixelBufferGetBytesPerRow(imageBuffer);
    if (srcBase == NULL) {
        return false;
    }

    if (EnsureRFXCanonical((int)width, (int)height) == false) {
        return false;
    }

    // dirty rect 정보는 current_frame 에 계속 기록한다.
    // (consumer 의 RFX 경로에서는 slot 안의 indices 를 사용하므로 이 dirtys 는 직접 쓰이지
    //  않지만, 다른 포맷과의 일관성 / 디버그 편의를 위해 유지한다.)
    PopulateDirtyRectsFromArray(dirtyRects, dirtyRectsCnt, (int)width, (int)height, current_frame);
    ApplyPendingDirty(displayIdx, current_frame);

    const size_t tileCols  = _rfxTileCols;
    const size_t tileRows  = _rfxTileRows;
    const size_t tileTotal = tileCols * tileRows;
    if (tileCols == 0 || tileRows == 0 || tileTotal == 0) {
        return false;
    }

    // full redraw 가 필요한지 판별
    bool doFullRedraw = _rfxFullRedrawRequired;
    if (!doFullRedraw && current_frame->dirtyCount <= 0) {
        doFullRedraw = true;
    }

    // dirty tile bitmap 구성
    const size_t maskSize = (tileTotal + 7) / 8;
    uint8_t  stackMask[2048];
    uint8_t* mask = (maskSize <= sizeof(stackMask)) ? stackMask : (uint8_t*)malloc(maskSize);
    if (mask == NULL) return false;

    auto computeMaskFromDirtyRects = [&]() -> bool {
        memset(mask, 0, maskSize);
        bool any = false;
        const int limitW = (int)width;
        const int limitH = (int)height;
        for (int i = 0; i < current_frame->dirtyCount && i < MAX_DIRTY_COUNT; ++i) {
            const struct RECT* r = &current_frame->dirtys[i];
            int x0 = r->x;
            int y0 = r->y;
            int x1 = r->x + r->width;
            int y1 = r->y + r->height;
            if (x0 < 0) x0 = 0;
            if (y0 < 0) y0 = 0;
            if (x1 > limitW) x1 = limitW;
            if (y1 > limitH) y1 = limitH;
            if (x1 <= x0 || y1 <= y0) continue;

            const int tx0 = x0 / 64;
            const int ty0 = y0 / 64;
            const int tx1 = (x1 - 1) / 64;
            const int ty1 = (y1 - 1) / 64;
            for (int ty = ty0; ty <= ty1; ++ty) {
                const size_t rowBase = (size_t)ty * tileCols;
                for (int tx = tx0; tx <= tx1; ++tx) {
                    const size_t bit = rowBase + (size_t)tx;
                    mask[bit >> 3] |= (uint8_t)(1u << (bit & 7));
                    any = true;
                }
            }
        }
        return any;
    };

    if (!doFullRedraw) {
        if (computeMaskFromDirtyRects() == false) {
            doFullRedraw = true;
        }
    }

    if (doFullRedraw) {
        memset(mask, 0xFF, maskSize);
        // tileTotal 이 8 의 배수가 아닐 때 초과 비트 클리어
        const size_t excessBits = (maskSize * 8) - tileTotal;
        if (excessBits > 0) {
            mask[maskSize - 1] = (uint8_t)(0xFFu >> excessBits);
        }
    }

    // tile 변환 (BGRA -> YUV444 planar)
    uint8_t* canonical = _rfxCanonical;
    const uint8_t* bgraBase = srcBase;
    const size_t bgraStride = srcStride;
    const int widthInt  = (int)width;
    const int heightInt = (int)height;
    _Atomic int convertFailed = 0;
    _Atomic int* convertFailedPtr = &convertFailed;

    dispatch_apply(tileRows, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^(size_t ty) {
        const size_t rowBase = ty * tileCols;
        for (size_t tx = 0; tx < tileCols; ++tx) {
            const size_t bit = rowBase + tx;
            if ((mask[bit >> 3] & (uint8_t)(1u << (bit & 7))) == 0) continue;

            uint8_t* tileBase = canonical + (bit * OSXRDP_RFX_TILE_BYTES);
            if (ConvertRFXTile(bgraBase, bgraStride, widthInt, heightInt, (int)tx, (int)ty, tileBase) == false) {
                atomic_store_explicit(convertFailedPtr, 1, memory_order_release);
            }
        }
    });

    if (atomic_load_explicit(&convertFailed, memory_order_acquire) != 0) {
        if (mask != stackMask) free(mask);
        return false;
    }

    // layout: [size_t imgSize][int tileCount][int indices[tileCount]][uint8 tileData[tileCount*16384]]
    int* slotCountPtr = (int*)(screenrecord_data + sizeof(size_t));
    int* slotIndices  = (int*)(screenrecord_data + sizeof(size_t) + sizeof(int));

    int slotTileCount = 0;
    for (size_t ty = 0; ty < tileRows; ++ty) {
        const size_t rowBase = ty * tileCols;
        for (size_t tx = 0; tx < tileCols; ++tx) {
            const size_t bit = rowBase + tx;
            if ((mask[bit >> 3] & (uint8_t)(1u << (bit & 7))) == 0) continue;
            slotIndices[slotTileCount++] = (int)bit;
        }
    }

    if (slotTileCount <= 0) {
        if (mask != stackMask) free(mask);
        return false;
    }

    *slotCountPtr = slotTileCount;

    // canonical → slot tileData 복사
    uint8_t* slotTileData = (uint8_t*)(slotIndices + slotTileCount);
    for (int i = 0; i < slotTileCount; ++i) {
        const int idx = slotIndices[i];
        memcpy(slotTileData + (size_t)i * OSXRDP_RFX_TILE_BYTES,
               _rfxCanonical + (size_t)idx * OSXRDP_RFX_TILE_BYTES,
               OSXRDP_RFX_TILE_BYTES);
    }

    const size_t imgSize = sizeof(int)
                         + sizeof(int) * (size_t)slotTileCount
                         + (size_t)slotTileCount * OSXRDP_RFX_TILE_BYTES;
    memcpy(screenrecord_data, &imgSize, sizeof(size_t));

    if (doFullRedraw) {
        _rfxFullRedrawRequired = false;
        current_frame->dirtyCount = 0;
    }

    if (mask != stackMask) free(mask);
    
    return true;
}

bool ScreenRecorderManager::EnsureRFXCanonical(int width, int height) {
    if (width <= 0 || height <= 0) {
        return false;
    }

    if (_rfxCanonical != NULL && _rfxCanonicalWidth == width && _rfxCanonicalHeight == height) {
        return true;
    }

    ReleaseRFXCanonical();

    const size_t tileCols = ((size_t)width + 63) / 64;
    const size_t tileRows = ((size_t)height + 63) / 64;
    const size_t size = tileCols * tileRows * 16384;

    _rfxCanonical = (uint8_t*)malloc(size);
    if (_rfxCanonical == NULL) {
        return false;
    }

    _rfxCanonicalSize      = size;
    _rfxCanonicalWidth     = width;
    _rfxCanonicalHeight    = height;
    _rfxTileCols           = tileCols;
    _rfxTileRows           = tileRows;
    _rfxFullRedrawRequired = true;
    
    memset(_rfxCanonical, 0, size);
    for (size_t ty = 0; ty < tileRows; ++ty) {
        const int top = (int)ty * 64;
        const int validHeight = (height - top < 64) ? (height - top) : 64;

        for (size_t tx = 0; tx < tileCols; ++tx) {
            const int left = (int)tx * 64;
            const int validWidth = (width - left < 64) ? (width - left) : 64;

            uint8_t* tileBase = _rfxCanonical + ((ty * tileCols + tx) * 16384);
            uint8_t* uPlane = tileBase + 4096;
            uint8_t* vPlane = tileBase + 8192;
            uint8_t* aPlane = tileBase + 12288;

            memset(aPlane, 0xFF, 4096);

            // 모서리 타일의 무효 영역 U/V 를 중립값 128 로 고정 (Y 는 이미 0)
            if (validWidth < 64) {
                const int stripW = 64 - validWidth;
                for (int py = 0; py < validHeight; ++py) {
                    memset(uPlane + (size_t)py * 64 + validWidth, 128, stripW);
                    memset(vPlane + (size_t)py * 64 + validWidth, 128, stripW);
                }
            }
            if (validHeight < 64) {
                const int stripRows = 64 - validHeight;
                memset(uPlane + (size_t)validHeight * 64, 128, (size_t)stripRows * 64);
                memset(vPlane + (size_t)validHeight * 64, 128, (size_t)stripRows * 64);
            }
        }
    }

    return true;
}

void ScreenRecorderManager::InvalidateRFXCanonical() {
    _rfxFullRedrawRequired = true;
}

void ScreenRecorderManager::ReleaseRFXCanonical() {
    if (_rfxCanonical != NULL) {
        free(_rfxCanonical);
        _rfxCanonical = NULL;
    }
    _rfxCanonicalSize      = 0;
    _rfxCanonicalWidth     = 0;
    _rfxCanonicalHeight    = 0;
    _rfxTileCols           = 0;
    _rfxTileRows           = 0;
    _rfxFullRedrawRequired = true;
}

bool ScreenRecorderManager::ConvertRFXTile(const uint8_t* bgraBase, size_t bgraStride, int width, int height,
                                           int tileCol, int tileRow, uint8_t* tileBase) {
    const int left = tileCol * 64;
    const int top  = tileRow * 64;
    const int validWidth  = (width  - left < 64) ? (width  - left) : 64;
    const int validHeight = (height - top  < 64) ? (height - top)  : 64;
    if (validWidth <= 0 || validHeight <= 0) {
        return false;
    }

    // RemoteFX 는 MS-RDPRFX 3.1.8.1.3 규격에 따라 BT.601 "full-range" (JFIF) 계수를 요구한다.
    //   Y  =  0.299 R + 0.587 G + 0.114 B
    //   Cb = -0.168736 R - 0.331264 G + 0.5 B + 128
    //   Cr =  0.5 R - 0.418688 G - 0.081312 B + 128
    // 따라서 matrix 는 ITU_R_601_*, pixelRange 는 { Yp_bias=0, CbCr_bias=128, YpRangeMax=255, CbCrRangeMax=255, YpMax=255, YpMin=0, CbCrMax=255, CbCrMin=0 }.
    static dispatch_once_t onceToken;
    static vImage_ARGBToYpCbCr conversionInfo;
    static bool hasConversionInfo = false;
    dispatch_once(&onceToken, ^{
        const vImage_YpCbCrPixelRange pixelRange = { 0, 128, 255, 255, 255, 0, 255, 0 };
        vImage_Error err = vImageConvert_ARGBToYpCbCr_GenerateConversion(
            kvImage_ARGBToYpCbCrMatrix_ITU_R_601_4,
            &pixelRange,
            &conversionInfo,
            kvImageARGB8888,
            kvImage444CrYpCb8,
            kvImageNoFlags);
        hasConversionInfo = (err == kvImageNoError);
    });
    if (hasConversionInfo == false) {
        return false;
    }

    const uint8_t bgraPermuteMap[4] = { 3, 2, 1, 0 }; // BGRA -> ARGB 매핑용

    vImage_Buffer srcBuffer = {
        (void*)(bgraBase + ((size_t)top * bgraStride) + ((size_t)left * 4)),
        (vImagePixelCount)validHeight,
        (vImagePixelCount)validWidth,
        bgraStride
    };

    uint8_t tempPackedCrYpCb[64 * 64 * 3];
    vImage_Buffer packedBuffer = {
        tempPackedCrYpCb,
        (vImagePixelCount)validHeight,
        (vImagePixelCount)validWidth,
        (size_t)validWidth * 3
    };

    // BGRA -> Packed CrYpCb (V, Y, U) -> Planar (Y/U/V 타일 다이렉트 쓰기)
    vImage_Error err = vImageConvert_ARGB8888To444CrYpCb8(&srcBuffer, &packedBuffer, &conversionInfo, bgraPermuteMap, kvImageNoFlags);
    if (err != kvImageNoError) {
        return false;
    }

    vImage_Buffer destV = { tileBase + 8192, (vImagePixelCount)validHeight, (vImagePixelCount)validWidth, 64 };
    vImage_Buffer destY = { tileBase,        (vImagePixelCount)validHeight, (vImagePixelCount)validWidth, 64 };
    vImage_Buffer destU = { tileBase + 4096, (vImagePixelCount)validHeight, (vImagePixelCount)validWidth, 64 };
    err = vImageConvert_RGB888toPlanar8(&packedBuffer, &destV, &destY, &destU, kvImageNoFlags);
    if (err != kvImageNoError) {
        return false;
    }

    return true;
}

inline void ScreenRecorderManager::ProcessDirtyArea(const CGRect* rect, int limX, int limY, struct RECT* dst) {
    const int orgX = (int)rect->origin.x;
    const int orgY = (int)rect->origin.y;
    const int orgW = (int)rect->size.width;
    const int orgH = (int)rect->size.height;

    // padding 추가 (이것이 없을 경우 화면 해상도가 1:1 이 아닌 경우 창의 끝부분 잔상이 남는 경우가 있음)
    // 4:2:0 정렬
    int x0 = (orgX - 4) & ~1;
    int y0 = (orgY - 4) & ~1;
    int x1 = (orgX + orgW + 5) & ~1;
    int y1 = (orgY + orgH + 5) & ~1;

    // 정렬로 인해 넘어간 경우 방지
    x0 = MAX(0, x0);
    y0 = MAX(0, y0);
    x1 = MIN(limX, x1);
    y1 = MIN(limY, y1);

    dst->x = x0;
    dst->y = y0;
    dst->width  = x1 - x0;
    dst->height = y1 - y0;
}


void ScreenRecorderManager::HandleRecordCommand(int cmd, void* userData) {
    ScreenRecorderManager* _this = (ScreenRecorderManager*)userData;

    if (cmd == 1) {
        _this->SendDisconnectMsgToClient();
    }
}
