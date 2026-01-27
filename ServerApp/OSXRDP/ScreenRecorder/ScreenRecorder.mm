#include <Accelerate/Accelerate.h>

#include "ScreenRecorder.h"
#include "osxrdp/packet.h"
#import "ScreenRecorderImpl.h"
#import "ScreenRecorderFallbackImpl.h"
#import <CoreMedia/CoreMedia.h>
#include "utils.h"


#define _GET_DISPLAY_USING_INDEX(idx) (__bridge_transfer SCDisplay*)GetDisplay((idx))
#define _GET_DISPLAY_USING_ID(id) (__bridge_transfer SCDisplay*)GetDisplayById((id))

#define _ALIGN_DOWN_EVEN(v)   ((v) & ~1)
#define _ALIGN_UP_EVEN(v)     (((v) + 1) & ~1)

ScreenRecorder::ScreenRecorder(bool useLegacyRecorder) :
    _impl(NULL),
    _implFallback(NULL),
    _recordShm(NULL),
    _encodingSession(NULL)
{
    if (useLegacyRecorder == false) {
        ScreenRecorderImpl* impl = [[ScreenRecorderImpl alloc] init];
        _impl = (__bridge_retained void*)impl;
    }
    else {
        ScreenRecorderFallbackImpl* implFallback = [[ScreenRecorderFallbackImpl alloc] init];
        _implFallback = (__bridge_retained void*)implFallback;
    }
}

ScreenRecorder::~ScreenRecorder() {
    Stop();
    
    if (_impl) {
        CFRelease(_impl);
        _impl = NULL;
    }
    
    if (_implFallback) {
        CFRelease(_implFallback);
        _implFallback = NULL;
    }
    
    // 가상 모니터 파괴
    _virtualMonitor.Destroy();
}

bool ScreenRecorder::StartRecord(xstream_t* cmd) {
    // parse cmd
    int monitorIndex = xstream_readInt32(cmd);
    (void)monitorIndex; // unused yet
    int width = xstream_readInt32(cmd);
    int height = xstream_readInt32(cmd);
    int framerate = xstream_readInt32(cmd);
    int recordFormat = xstream_readInt32(cmd);
    int useVirtualMon = xstream_readInt32(cmd);
    
    // 잠금화면의 경우 virtual monitor 를 지원하지 않음.
    if (is_root_process() != 0) {
        useVirtualMon = 0;
    }
    
    if (framerate > 60) {
        framerate = 60;
    }
    else if (framerate < 30) {
        framerate = 30;
    }
    
    if (width <= 0 || height <= 0) {
        return false;
    }
    
    width &= ~0x1;
    height &= ~0x1;

    SCDisplay* display = nil;
    if (useVirtualMon != 0) {
        int monId = _virtualMonitor.Create(width, height);
        if (monId == -1) {
            display = _GET_DISPLAY_USING_INDEX(0);
            if (display == nil){
                return false;
            }
        }
        else {
            display = _GET_DISPLAY_USING_ID(monId);
            if (display == nil){
                return false;
            }
            
            _virtualMonitor.DisableOtherMonitors();
        }
        
        // macOS 12 에서 가상 디스플레이의 width, height 가 1로 오는 증상이 발생...
        // 가상 디스플레이는 클라이언트의 해상도를 따라가므로 동일하게 설정
        //_inputHandler.UpdateDisplayRes((int)display.width, (int)display.height, width, height);
        _inputHandler.UpdateDisplayRes(width, height, width, height);
    }
    else {
        display = _GET_DISPLAY_USING_INDEX(0);
        if (display == nil){
            return false;
        }
        
        _inputHandler.UpdateDisplayRes((int)display.width, (int)display.height, width, height);
    }

    if (CreateRecordShm(width, height, framerate) == false) {
        return false;
    }
    
    if (_impl != NULL) {
        ScreenRecorderImpl* impl = (__bridge ScreenRecorderImpl*)_impl;
        if (recordFormat == OSXRDP_RECORDFORMAT_NV12) {
            [impl initializeWithDisplay:display
                            RecordWidth:width RecordHeight:height
                            RecordFramerate:framerate RecordFormat:recordFormat
                            RecordDataCallback:HandleNV12RecordData RecordDataCallbackUserData:this
                            RecordCmdCallback:HandleRecordCommand RecordCmdCallbackUserData:this];
        }
        else {
            [impl initializeWithDisplay:display
                            RecordWidth:width RecordHeight:height
                            RecordFramerate:framerate RecordFormat:recordFormat
                            RecordDataCallback:HandleBGRA32RecordData RecordDataCallbackUserData:this
                            RecordCmdCallback:HandleRecordCommand RecordCmdCallbackUserData:this];
        }
        
        return [impl start];
    }
    else {
        ScreenRecorderFallbackImpl* fallbackImpl = (__bridge ScreenRecorderFallbackImpl*)_implFallback;
        if (recordFormat == OSXRDP_RECORDFORMAT_NV12) {
            [fallbackImpl initializeWithDisplay:display
                            RecordWidth:width RecordHeight:height
                            RecordFramerate:framerate RecordFormat:recordFormat
                            RecordDataCallback:HandleFallbackNV12RecordData RecordDataCallbackUserData:this
                            RecordCmdCallback:HandleRecordCommand RecordCmdCallbackUserData:this];
            
        }
        else {
            [fallbackImpl initializeWithDisplay:display
                            RecordWidth:width RecordHeight:height
                            RecordFramerate:framerate RecordFormat:recordFormat
                            RecordDataCallback:HandleFallbackBGRA32RecordData RecordDataCallbackUserData:this
                            RecordCmdCallback:HandleRecordCommand RecordCmdCallbackUserData:this];
        }
        
        return [fallbackImpl start];
    }
}

bool ScreenRecorder::CreateRecordShm(int width, int height, int framerate) {
    if (_recordShm != NULL) {
        NSLog(@"[ScreenRecorder::CreateRecordShm] recordShm is already exists.");
        
        return false;
    }
    
    int rawDataSize = width * height * 5;
    
    char shm_name[512];
    if (is_root_process() == 0) {
        if (get_object_name_by_sessionid("/osxrdpshm", shm_name, 512) == 0) {
            return false;
        }
    }
    else {
        if (get_object_name_by_sessionid("/osxrdpshm_l", shm_name, 512) == 0) {
            return false;
        }
    }

    _recordShm = xshm_create(shm_name, sizeof(screenrecord_shm_t) + (rawDataSize * FRAME_SLOTS));
    if (_recordShm == NULL) {
        NSLog(@"[ScreenRecorder::CreateRecordShm] xshm_create failed.");
        
        return false;
    }
    
    memset(_recordShm->mem, 0x00, sizeof(screenrecord_shm_t) + (rawDataSize * FRAME_SLOTS));
    
    screenrecord_shm_t* shm = (screenrecord_shm_t*)_recordShm->mem;
    shm->width = width;
    shm->height = height;
    shm->fps = framerate;
    shm->screenrecord_data_size = rawDataSize;
    
    return true;
}

void ScreenRecorder::DestroyRecordShm() {
    if (_recordShm == NULL) {
        return;
    }
    
    xshm_close(_recordShm);
    xshm_destroy(_recordShm);
    _recordShm = NULL;
}

void ScreenRecorder::Stop() {
    if (_impl == NULL && _implFallback == NULL) return;
        
    // 화면 녹화를 먼저 정지
    if (_impl != NULL) {
        ScreenRecorderImpl* impl = (__bridge ScreenRecorderImpl*)_impl;
        if ([impl stop] == NO) {
            // 정지 실패 (간혹 빠르게 호출하면 이럼)
            sleep(1);
            
            // 재시도
            [impl stop];
        }
    }
    else {
        ScreenRecorderFallbackImpl* implFallback = (__bridge ScreenRecorderFallbackImpl*)_implFallback;
        if ([implFallback stop] == NO) {
            // 정지 실패 (간혹 빠르게 호출하면 이럼)
            sleep(1);
            
            // 재시도
            [implFallback stop];
        }
    }
    
    _virtualMonitor.Destroy();
    
    // 공유 메모리 정리
    DestroyRecordShm();
}

void ScreenRecorder::HandleCommand(xipc_t* client, xstream_t* cmd) {
    if (cmd == NULL) return;
    
    int packetType = xstream_readInt32(cmd);
    
    switch (packetType) {
        case OSXRDP_PACKETTYPE_REQ_SCREEN: {
            bool re = StartRecord(cmd);
            
            _client = client;
            
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
            Stop();
            break;
        }
        case OSXRDP_PACKETTYPE_MOUSEEVT: {
            _inputHandler.HandleMousseInputEvent(cmd);
            break;
        }
        case OSXRDP_PACKETTYPE_KEYBOARDEVT: {
            _inputHandler.HandleKeyboardInputEvent(cmd);
            break;
        }
    }
}

void ScreenRecorder::SendDisconnectMsgToClient() {
    struct stop_msg {
        int cmdType;
        int packetType;
    };
    
    // 가상 모니터를 먼저 파괴 (todo : 정확한 정리 타이밍을 다시 정하기)
    // 2개 이상의 클라이언트가 겹치면 충돌나서 원본 물리 화면이 안나오는 경우가 발생.
    _virtualMonitor.Destroy();
    
    struct stop_msg msg = { OSXRDP_CMDTYPE_MSGFROMAGENT, OSXRDP_PACKETTYPE_TERMINATE };
    xipc_send_data(_client, &msg, sizeof(msg));
}

void* ScreenRecorder::GetDisplay(int unused) {
    __block SCDisplay* found = nil;
    
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent * _Nullable content, NSError * _Nullable error) {
        found = content.displays.firstObject;
        dispatch_semaphore_signal(sema);
    }];

    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);

    return (__bridge_retained void*)found;
}

void* ScreenRecorder::GetDisplayById(int monitorId) {
    __block SCDisplay* found = nil;
    
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent * _Nullable content, NSError * _Nullable error) {
        for (SCDisplay* item in content.displays) {
            if (item.displayID == monitorId) {
                found = item;
                break;
            }
        }
        dispatch_semaphore_signal(sema);
    }];

    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);

    return (__bridge_retained void*)found;
}

void ScreenRecorder::HandleNV12RecordData(void* sampleBuffer, void* imgBuffer, void* userData) {
    if (sampleBuffer == NULL || userData == NULL) return;
    
    ScreenRecorder* _this = (ScreenRecorder*)userData;
    
    screenrecord_shm_t* recordInfo = (screenrecord_shm_t*)_this->_recordShm->mem;
    
    unsigned int readPos = atomic_load_explicit(&recordInfo->read_pos, memory_order_acquire);
    unsigned int writePos = atomic_load_explicit(&recordInfo->write_pos, memory_order_relaxed);
    
    // 아직 소비하지 못한 데이터가 너무 많은 경우 버리기 (drop)
    if (writePos - readPos >= FRAME_SLOTS) {
        return;
    }
        
    int index = writePos % FRAME_SLOTS;
    
    screenrecord_frame* slot = &recordInfo->frames[index];
    char* screenrecord_data = *(&recordInfo->screenrecord_datas + (recordInfo->screenrecord_data_size * index));
    HandleNV12DirtyArea(sampleBuffer, imgBuffer, slot, screenrecord_data);

    atomic_store_explicit(&recordInfo->write_pos, writePos + 1, memory_order_release);
    
    int dummy = OSXRDP_CMDTYPE_DUMMY;
    xipc_send_data(_this->_client, (void*)&dummy, sizeof(int));
}

void ScreenRecorder::HandleBGRA32RecordData(void* sampleBuffer, void* imgBuffer, void* userData) {
    if (sampleBuffer == NULL || userData == NULL) return;
    
    ScreenRecorder* _this = (ScreenRecorder*)userData;
    
    screenrecord_shm_t* recordInfo = (screenrecord_shm_t*)_this->_recordShm->mem;
    
    unsigned int readPos = atomic_load_explicit(&recordInfo->read_pos, memory_order_acquire);
    unsigned int writePos = atomic_load_explicit(&recordInfo->write_pos, memory_order_relaxed);
    
    // 아직 소비하지 못한 데이터가 너무 많은 경우 버리기 (drop)
    if (writePos - readPos >= FRAME_SLOTS) {
        return;
    }
        
    int index = writePos % FRAME_SLOTS;
    
    screenrecord_frame* slot = &recordInfo->frames[index];
    char* screenrecord_data = *(&recordInfo->screenrecord_datas + (recordInfo->screenrecord_data_size * index));
    HandleBGRA32DirtyArea(sampleBuffer, imgBuffer, slot, screenrecord_data);

    atomic_store_explicit(&recordInfo->write_pos, writePos + 1, memory_order_release);
    
    int dummy = OSXRDP_CMDTYPE_DUMMY;
    xipc_send_data(_this->_client, (void*)&dummy, sizeof(int));
}

void ScreenRecorder::HandleNV12DirtyArea(void* sampleBuffer, void* imgBuffer, screenrecord_frame* current_frame, char* screenrecord_data) {
    CMSampleBufferRef buffer = (CMSampleBufferRef)sampleBuffer;
    CVImageBufferRef imageBuffer = (CVImageBufferRef)imgBuffer;
    if (imageBuffer == NULL) {
        return;
    }

    size_t width = CVPixelBufferGetWidth(imageBuffer);
    size_t height = CVPixelBufferGetHeight(imageBuffer);

    uint8_t* ySrcBase = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0);
    size_t yStride = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0);

    uint8_t* uvSrcBase = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 1);
    size_t uvStride = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 1);

    size_t packedImgSize = (width * height) + (width * (height / 2));

    const size_t rowBytes = width;

    // 공유 메모리 헤더 작성 (크기 정보)
    memcpy(screenrecord_data, &packedImgSize, sizeof(size_t));
    uint8_t* dstData = (uint8_t*)(screenrecord_data + sizeof(size_t));

    if (yStride == rowBytes) {
        // 패딩이 없으면 한 번에 복사
        memcpy(dstData, ySrcBase, rowBytes * height);
    }
    else {
        // 패딩이 있으면 한 줄씩 복사
        uint8_t* src = ySrcBase;
        uint8_t* dst = dstData;
        for (size_t row = 0; row < height; ++row) {
            memcpy(dst, src, rowBytes);
            src += yStride;
            dst += rowBytes;
        }
    }

    uint8_t* dstUV = dstData + (width * height); // Y 데이터 끝 바로 다음
    const size_t uvHeight = height / 2;

    if (uvStride == rowBytes) {
        // 패딩이 없으면 한 번에 복사
        memcpy(dstUV, uvSrcBase, rowBytes * uvHeight);
    }
    else {
        uint8_t* src = uvSrcBase;
        uint8_t* dst = dstUV;
        for (size_t row = 0; row < uvHeight; ++row) {
            memcpy(dst, src, rowBytes);
            src += uvStride;
            dst += rowBytes;
        }
    }
        
    current_frame->dirtyCount = 0;
    
    // dirty info 들을 복사 시도 (있는 경우)
    CFArrayRef arr = CMSampleBufferGetSampleAttachmentsArray(buffer, false);
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

        ProcessDirtyArea(&tmp, (int)width, (int)height, &(current_frame->dirtys[i]));
    }
}

void ScreenRecorder::HandleBGRA32DirtyArea(void* sampleBuffer, void* imgBuffer, screenrecord_frame* current_frame, char* screenrecord_data) {
    CMSampleBufferRef buffer = (CMSampleBufferRef)sampleBuffer;
    CVImageBufferRef imageBuffer = (CVImageBufferRef)imgBuffer;
    if (imageBuffer == NULL) {
        return;
    }

    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
    size_t width = CVPixelBufferGetWidth(imageBuffer);
    size_t height = CVPixelBufferGetHeight(imageBuffer);
    
    uint8_t* rawImageBuffer = (uint8_t*)CVPixelBufferGetBaseAddress(imageBuffer);
    if (rawImageBuffer == NULL || width == 0 || height == 0) {
        return;
    }
    
    size_t rowSize = width * 4;
    size_t imgSize = rowSize * height;

    // 1프레임의 이미지를 공유 메모리에 복사
    memcpy(screenrecord_data, &imgSize, sizeof(size_t));
    
    // 이미지 복사 (패딩을 제거하면서)
    uint8_t* dest = (uint8_t*)screenrecord_data + sizeof(size_t);
    for (size_t y = 0; y < height; ++y) {
        memcpy(dest + y * rowSize, rawImageBuffer + (y * bytesPerRow), rowSize);
    }
        
    current_frame->dirtyCount = 0;
    
    // dirty info 들을 복사 시도 (있는 경우)
    CFArrayRef arr = CMSampleBufferGetSampleAttachmentsArray(buffer, false);
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

        ProcessDirtyArea(&tmp, (int)width, (int)height, &(current_frame->dirtys[i]));
    }
}

void ScreenRecorder::HandleFallbackNV12RecordData(void* pixelBuffer, const CGRect* dirtyRects, int dirtyRectsCnt, void* userData){
    if (pixelBuffer == NULL || userData == NULL) return;
    
    ScreenRecorder* _this = (ScreenRecorder*)userData;
    
    screenrecord_shm_t* recordInfo = (screenrecord_shm_t*)_this->_recordShm->mem;
    
    unsigned int readPos = atomic_load_explicit(&recordInfo->read_pos, memory_order_acquire);
    unsigned int writePos = atomic_load_explicit(&recordInfo->write_pos, memory_order_relaxed);
    
    // 아직 소비하지 못한 데이터가 너무 많은 경우 버리기 (drop)
    if (writePos - readPos >= FRAME_SLOTS) {
        return;
    }
        
    int index = writePos % FRAME_SLOTS;
    
    screenrecord_frame* slot = &recordInfo->frames[index];
    char* screenrecord_data = *(&recordInfo->screenrecord_datas + (recordInfo->screenrecord_data_size * index));
    HandleFallbackNV12DirtyArea(pixelBuffer, slot, dirtyRects, dirtyRectsCnt, screenrecord_data);

    atomic_store_explicit(&recordInfo->write_pos, writePos + 1, memory_order_release);
    
    int dummy = OSXRDP_CMDTYPE_DUMMY;
    xipc_send_data(_this->_client, (void*)&dummy, sizeof(int));
}

void ScreenRecorder::HandleFallbackNV12DirtyArea(void* pixelBuffer, screenrecord_frame* current_frame, const CGRect* dirtyRects, int dirtyRectsCnt, char* screenrecord_data) {
    CVImageBufferRef imageBuffer = (CVImageBufferRef)pixelBuffer;
    if (imageBuffer == NULL) {
        return;
    }

    size_t width = CVPixelBufferGetWidth(imageBuffer);
    size_t height = CVPixelBufferGetHeight(imageBuffer);

    uint8_t* ySrcBase = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0);
    size_t yStride = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0);

    uint8_t* uvSrcBase = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 1);
    size_t uvStride = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 1);

    size_t packedImgSize = (width * height) + (width * (height / 2));

    const size_t rowBytes = width;

    // 공유 메모리 헤더 작성 (크기 정보)
    memcpy(screenrecord_data, &packedImgSize, sizeof(size_t));
    uint8_t* dstData = (uint8_t*)(screenrecord_data + sizeof(size_t));

    if (yStride == rowBytes) {
        // 패딩이 없으면 한 번에 복사
        memcpy(dstData, ySrcBase, rowBytes * height);
    }
    else {
        // 패딩이 있으면 한 줄씩 복사
        uint8_t* src = ySrcBase;
        uint8_t* dst = dstData;
        for (size_t row = 0; row < height; ++row) {
            memcpy(dst, src, rowBytes);
            src += yStride;
            dst += rowBytes;
        }
    }

    uint8_t* dstUV = dstData + (width * height); // Y 데이터 끝 바로 다음
    const size_t uvHeight = height / 2;

    if (uvStride == rowBytes) {
        // 패딩이 없으면 한 번에 복사
        memcpy(dstUV, uvSrcBase, rowBytes * uvHeight);
    }
    else {
        uint8_t* src = uvSrcBase;
        uint8_t* dst = dstUV;
        for (size_t row = 0; row < uvHeight; ++row) {
            memcpy(dst, src, rowBytes);
            src += uvStride;
            dst += rowBytes;
        }
    }
        
    current_frame->dirtyCount = 0;

    current_frame->dirtyCount = dirtyRectsCnt;
    if (current_frame->dirtyCount < 0 || current_frame->dirtyCount > MAX_DIRTY_COUNT) {
        current_frame->dirtyCount = 0;
        return;
    }
    
    CGRect tmp;
    for (int i = 0; i < current_frame->dirtyCount; i++) {
        memcpy(&tmp, &dirtyRects[i], sizeof(CGRect));

        ProcessDirtyArea(&tmp, (int)width, (int)height, &(current_frame->dirtys[i]));
    }
}

void ScreenRecorder::HandleFallbackBGRA32RecordData(void* pixelBuffer, const CGRect* dirtyRects, int dirtyRectsCnt, void* userData){
    if (pixelBuffer == NULL || userData == NULL) return;
    
    ScreenRecorder* _this = (ScreenRecorder*)userData;
    
    screenrecord_shm_t* recordInfo = (screenrecord_shm_t*)_this->_recordShm->mem;
    
    unsigned int readPos = atomic_load_explicit(&recordInfo->read_pos, memory_order_acquire);
    unsigned int writePos = atomic_load_explicit(&recordInfo->write_pos, memory_order_relaxed);
    
    // 아직 소비하지 못한 데이터가 너무 많은 경우 버리기 (drop)
    if (writePos - readPos >= FRAME_SLOTS) {
        return;
    }
        
    int index = writePos % FRAME_SLOTS;
    
    screenrecord_frame* slot = &recordInfo->frames[index];
    char* screenrecord_data = *(&recordInfo->screenrecord_datas + (recordInfo->screenrecord_data_size * index));
    HandleFallbackBGRA32DirtyArea(pixelBuffer, slot, dirtyRects, dirtyRectsCnt, screenrecord_data);

    atomic_store_explicit(&recordInfo->write_pos, writePos + 1, memory_order_release);
    
    int dummy = OSXRDP_CMDTYPE_DUMMY;
    xipc_send_data(_this->_client, (void*)&dummy, sizeof(int));
}

void ScreenRecorder::HandleFallbackBGRA32DirtyArea(void* pixelBuffer, screenrecord_frame* current_frame, const CGRect* dirtyRects, int dirtyRectsCnt, char* screenrecord_data) {
    CVImageBufferRef imageBuffer = (CVImageBufferRef)pixelBuffer;
    if (imageBuffer == NULL) {
        return;
    }

    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
    size_t width = CVPixelBufferGetWidth(imageBuffer);
    size_t height = CVPixelBufferGetHeight(imageBuffer);
    
    uint8_t* rawImageBuffer = (uint8_t*)CVPixelBufferGetBaseAddress(imageBuffer);
    if (rawImageBuffer == NULL || width == 0 || height == 0) {
        return;
    }
    
    size_t rowSize = width * 4;
    size_t imgSize = rowSize * height;

    // 1프레임의 이미지를 공유 메모리에 복사
    memcpy(screenrecord_data, &imgSize, sizeof(size_t));
    
    // 이미지 복사 (패딩을 제거하면서)
    uint8_t* dest = (uint8_t*)screenrecord_data + sizeof(size_t);
    for (size_t y = 0; y < height; ++y) {
        memcpy(dest + y * rowSize, rawImageBuffer + (y * bytesPerRow), rowSize);
    }
    
    current_frame->dirtyCount = 0;

    current_frame->dirtyCount = dirtyRectsCnt;
    if (current_frame->dirtyCount < 0 || current_frame->dirtyCount > MAX_DIRTY_COUNT) {
        current_frame->dirtyCount = 0;
        return;
    }
    
    CGRect tmp;
    for (int i = 0; i < current_frame->dirtyCount; i++) {
        memcpy(&tmp, &dirtyRects[i], sizeof(CGRect));
        ProcessDirtyArea(&tmp, (int)width, (int)height, &(current_frame->dirtys[i]));
    }
}

inline void ScreenRecorder::ProcessDirtyArea(const CGRect* rect, int limX, int limY, struct RECT* dst) {
    const short orgX = rect->origin.x;
    const short orgY = rect->origin.y;
    const short orgW = rect->size.width;
    const short orgH = rect->size.height;

    // padding 추가 (이것이 없을 경우 화면 해상도가 1:1 이 아닌 경우 창의 끝부분 잔상이 남는 경우가 있음)
    int x0 = (int)orgX - 1;
    int y0 = (int)orgY - 1;
    int x1 = (int)(orgX + orgW + 2);
    int y1 = (int)(orgY + orgH + 2);

    // 4:2:0 정렬
    x0 = _ALIGN_DOWN_EVEN(x0);
    y0 = _ALIGN_DOWN_EVEN(y0);
    x1 = _ALIGN_UP_EVEN(x1);
    y1 = _ALIGN_UP_EVEN(y1);

    // 정렬로 인해 넘어간 경우 방지
    x0 = MAX(0, x0);
    y0 = MAX(0, y0);
    x1 = MIN(limX, x1);
    y1 = MIN(limY, y1);

    if (x1 <= x0) {
        x1 = MIN(limX, x0 + 2);
        x0 = _ALIGN_DOWN_EVEN(MAX(0, x1 - 2));
    }
    
    if (y1 <= y0) {
        y1 = MIN(limY, y0 + 2);
        y0 = _ALIGN_DOWN_EVEN(MAX(0, y1 - 2));
    }

    dst->x = x0;
    dst->y = y0;
    dst->width  = x1 - x0;
    dst->height = y1 - y0;
}


void ScreenRecorder::HandleRecordCommand(int cmd, void* userData) {
    ScreenRecorder* _this = (ScreenRecorder*)userData;

    if (cmd == 1) {
        _this->SendDisconnectMsgToClient();
    }
}
