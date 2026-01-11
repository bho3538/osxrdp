#include <Accelerate/Accelerate.h>

#include "ScreenRecorder.h"
#include "osxrdp/packet.h"
#import "ScreenRecorderImpl.h"
#import <CoreMedia/CoreMedia.h>
#include "utils.h"


#define _GET_DISPLAY_USING_INDEX(idx) (__bridge_transfer SCDisplay*)GetDisplay((idx))
#define _ALIGN_DOWN_EVEN(v)   ((v) & ~1)
#define _ALIGN_UP_EVEN(v)     (((v) + 1) & ~1)

static volatile int g_fullredraw = 1;

ScreenRecorder::ScreenRecorder() :
    _impl(NULL),
    _recordShm(NULL),
    _encodingSession(NULL)
{
    ScreenRecorderImpl* impl = [[ScreenRecorderImpl alloc] init];
    _impl = (__bridge_retained void*)impl;
    
}

ScreenRecorder::~ScreenRecorder() {
    Stop();
    
    if (_impl) {
        CFRelease(_impl);
        _impl = NULL;
    }
}

bool ScreenRecorder::StartRecord(xstream_t* cmd) {
    // parse cmd
    int monitorIndex = xstream_readInt32(cmd);
    int width = xstream_readInt32(cmd);
    int height = xstream_readInt32(cmd);
    int framerate = xstream_readInt32(cmd);
    int recordFormat = xstream_readInt32(cmd);
    
    if (framerate > 60) {
        framerate = 60;
    }
    else if (framerate < 30) {
        framerate = 30;
    }
    
    if (width <= 0 || height <= 0) {
        return false;
    }

    SCDisplay* display = _GET_DISPLAY_USING_INDEX(monitorIndex);
    if (display == nil){
        return false;
    }
    
    _inputHandler = new InputHandler();
    _inputHandler->UpdateDisplayRes((int)display.width, (int)display.height, width, height);

    if (CreateRecordShm(width, height, framerate) == false) {
        return false;
    }
    
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
    
    [impl start];
    
    return true;
}

bool ScreenRecorder::CreateRecordShm(int width, int height, int framerate) {
    if (_recordShm != NULL) {
        NSLog(@"[ScreenRecorder::CreateRecordShm] recordShm is already exists.");
        
        return false;
    }
    
    int rawDataSize = width * height * 5;
    
    char shm_name[512];
    if (get_object_name_by_username("/osxrdpshm", shm_name, 512) == 0) {
        return false;
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
    if (_impl == NULL) return;
        
    // 화면 녹화를 먼저 정지
    ScreenRecorderImpl* impl = (__bridge ScreenRecorderImpl*)_impl;
    
    if ([impl stop] == NO) {
        // 정지 실패 (간혹 빠르게 호출하면 이럼)
        sleep(1);
        
        // 재시도
        [impl stop];
    }
    
    // 공유 메모리 정리
    DestroyRecordShm();
    
    delete _inputHandler;
    _inputHandler = NULL;
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
            _inputHandler->HandleMousseInputEvent(cmd);
            break;
        }
        case OSXRDP_PACKETTYPE_KEYBOARDEVT: {
            _inputHandler->HandleKeyboardInputEvent(cmd);
            break;
        }
    }
}

void ScreenRecorder::SendDisconnectMsgToClient() {
    struct stop_msg {
        int cmdType;
        int packetType;
    };
    
    struct stop_msg msg = { OSXRDP_CMDTYPE_MSGFROMAGENT, OSXRDP_PACKETTYPE_TERMINATE };
    xipc_send_data(_client, &msg, sizeof(msg));
}

void* ScreenRecorder::GetDisplay(int monitorIndex) {
    __block SCDisplay* found = nil;
    
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent * _Nullable content, NSError * _Nullable error) {
        found = content.displays.firstObject;
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
        g_fullredraw = 1;
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
        g_fullredraw = 1;
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

    // 공유 메모리 헤더 작성 (크기 정보)
    memcpy(screenrecord_data, &packedImgSize, sizeof(size_t));

    // 데이터 쓰기 시작 위치
    uint8_t* dstData = (uint8_t*)(screenrecord_data + sizeof(size_t));

    // copy y plain
    for (size_t row = 0; row < height; row++) {
        memcpy(dstData + (row * width), ySrcBase + (row * yStride), width);
    }

    // copy uv plain
    size_t yDataSize = width * height;
    uint8_t* dstUV = dstData + yDataSize;

    for (size_t row = 0; row < height / 2; row++) {
        memcpy(dstUV + (row * width), uvSrcBase + (row * uvStride), width);
    }
        
    current_frame->dirtyCount = 0;
    
    if (g_fullredraw == 1) {
        g_fullredraw = 0;
        return;
    }
    
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
    
    CGFloat limitX = (CGFloat)width;
    CGFloat limitY = (CGFloat)height;
    
    for (int i = 0; i < current_frame->dirtyCount; i++) {
        CFTypeRef element = CFArrayGetValueAtIndex(dirtyArr, i);
        CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)element, &current_frame->dirtys[i]);

        const CGFloat orgX = current_frame->dirtys[i].origin.x;
        const CGFloat orgY = current_frame->dirtys[i].origin.y;
        const CGFloat orgW = current_frame->dirtys[i].size.width;
        const CGFloat orgH = current_frame->dirtys[i].size.height;

        const int limX = (int)limitX;
        const int limY = (int)limitY;

        // padding 추가 (이것이 없을 경우 화면 해상도가 1:1 이 아닌 경우 창의 끝부분 잔상이 남는 경우가 있음)
        int x0 = (int)floor(orgX) - 2;
        int y0 = (int)floor(orgY) - 2;
        int x1 = (int)ceil(orgX + orgW) + 2;
        int y1 = (int)ceil(orgY + orgH) + 2;

        x0 = MAX(0, x0);
        y0 = MAX(0, y0);
        x1 = MIN(limX, x1);
        y1 = MIN(limY, y1);

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

        current_frame->dirtys[i].origin.x = (CGFloat)x0;
        current_frame->dirtys[i].origin.y = (CGFloat)y0;
        current_frame->dirtys[i].size.width  = (CGFloat)(x1 - x0);
        current_frame->dirtys[i].size.height = (CGFloat)(y1 - y0);
    }
}

void ScreenRecorder::HandleBGRA32DirtyArea(void* sampleBuffer, void* imgBuffer, screenrecord_frame* current_frame, char* screenrecord_data) {
    CMSampleBufferRef buffer = (CMSampleBufferRef)sampleBuffer;
    CVImageBufferRef imageBuffer = (CVImageBufferRef)imgBuffer;
    if (imageBuffer == NULL) {
        return;
    }

    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
    size_t height = CVPixelBufferGetHeight(imageBuffer);
    size_t imgSize = bytesPerRow * height;
    
    void* rawImageBuffer = CVPixelBufferGetBaseAddress(imageBuffer);
    if (rawImageBuffer == NULL || imgSize == 0) {
        return;
    }
    
    // 1프레임의 이미지를 공유 메모리에 복사
    memcpy(screenrecord_data, &imgSize, sizeof(size_t));
    memcpy(screenrecord_data + sizeof(size_t), rawImageBuffer, imgSize);
    
    current_frame->dirtyCount = 0;
    
    if (g_fullredraw == 1) {
        g_fullredraw = 0;
        return;
    }
    
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
    
    for (int i = 0; i < current_frame->dirtyCount; i++) {
        CFTypeRef element = CFArrayGetValueAtIndex(dirtyArr, i);
        CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)element, &current_frame->dirtys[i]);
    }
}

void ScreenRecorder::HandleRecordCommand(int cmd, void* userData) {
    ScreenRecorder* _this = (ScreenRecorder*)userData;

    if (cmd == 1) {
        _this->SendDisconnectMsgToClient();
    }
}
