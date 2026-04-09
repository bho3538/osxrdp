#include <Accelerate/Accelerate.h>

#include "ScreenRecorder.h"
#include "osxrdp/packet.h"
#import "ScreenRecorderImpl.h"
#import "ScreenRecorderFallbackImpl.h"
#import "../VirtualMon/DisplayUtils.h"
#import <CoreMedia/CoreMedia.h>
#include "utils.h"


#define _GET_DISPLAY_USING_INDEX(idx) (__bridge_transfer SCDisplay*)GetDisplay((idx))
#define _GET_DISPLAY_USING_ID(id) (__bridge_transfer SCDisplay*)GetDisplayById((id))

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

bool ConvertBGRA8888ToRFXPlanarTilesSHM(const uint8_t* bgraBase, size_t bgraStride, int width, int height, uint8_t* shmBase) {
    if (bgraBase == NULL || shmBase == NULL || width <= 0 || height <= 0) {
        return false;
    }

    static dispatch_once_t onceToken;
    static vImage_ARGBToYpCbCr conversionInfo;
    static bool hasConversionInfo = false;
    
    dispatch_once(&onceToken, ^{
        const vImage_YpCbCrPixelRange pixelRange = { 16, 128, 235, 240, 255, 0, 255, 1 };
        vImage_Error err = vImageConvert_ARGBToYpCbCr_GenerateConversion(
            kvImage_ARGBToYpCbCrMatrix_ITU_R_709_2,
            &pixelRange,
            &conversionInfo,
            kvImageARGB8888,
            kvImage444CrYpCb8,
            kvImageNoFlags
        );
        hasConversionInfo = (err == kvImageNoError);
    });

    if (!hasConversionInfo) return false;

    const int tileCols = (width + 63) / 64;
    const int tileRows = (height + 63) / 64;
    const size_t tileShmSize = 64 * 64 * 4; // 16KB (Y, U, V, A 각각 4096바이트)

    dispatch_apply(tileRows, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^(size_t ty) {
        const uint8_t bgraPermuteMap[4] = { 3, 2, 1, 0 }; // BGRA -> ARGB 매핑용

        for (int tx = 0; tx < tileCols; ++tx) {
            const int left = tx * 64;
            const int top = (int)ty * 64;
            const int validWidth = (width - left < 64) ? (width - left) : 64;
            const int validHeight = (height - top < 64) ? (height - top) : 64;

            // 타일 index 구하기
            const int tileIdx = (int)ty * tileCols + tx;
            uint8_t* shmTileBase = shmBase + (tileIdx * tileShmSize);
            
            uint8_t* yPlane = shmTileBase;              // Offset 0
            uint8_t* uPlane = shmTileBase + 4096;       // Offset 4096
            uint8_t* vPlane = shmTileBase + 8192;       // Offset 8192
            uint8_t* aPlane = shmTileBase + 12288;      // Offset 12288

            // Alpha 채널은 일괄 0xFF (투명도 없음) 처리
            memset(aPlane, 0xFF, 4096);

            // 입력 원본 BGRA의 64x64 구역 지정
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

            // BGRA -> Packed CrYpCb (V-Y-U) 변환
            vImageConvert_ARGB8888To444CrYpCb8(&srcBuffer, &packedBuffer, &conversionInfo, bgraPermuteMap, kvImageNoFlags);

            // 변환된 Packed 데이터를 분리하여 SHM Planar 영역에 바로 쓰기
            // tempPacked의 순서가 Cr(V), Yp(Y), Cb(U) 이므로, Red/Green/Blue 목적지에 맞게 맵핑
            vImage_Buffer destV = { vPlane, (vImagePixelCount)validHeight, (vImagePixelCount)validWidth, 64 };
            vImage_Buffer destY = { yPlane, (vImagePixelCount)validHeight, (vImagePixelCount)validWidth, 64 };
            vImage_Buffer destU = { uPlane, (vImagePixelCount)validHeight, (vImagePixelCount)validWidth, 64 };

            // Packed (V, Y, U) -> 분리된 Planar 타일 (SHM 다이렉트 쓰기)
            vImageConvert_RGB888toPlanar8(&packedBuffer, &destV, &destY, &destU, kvImageNoFlags);

            // 우측/하단 모서리 타일의 잉여 영역(Padding) 처리
            if (validWidth < 64 || validHeight < 64) {
                for (int py = 0; py < 64; ++py) {
                    for (int px = 0; px < 64; ++px) {
                        if (py >= validHeight || px >= validWidth) {
                            const size_t p = (size_t)py * 64 + (size_t)px;
                            yPlane[p] = 0;
                            uPlane[p] = 128;
                            vPlane[p] = 128;
                        }
                    }
                }
            }
        }
    });

    return true;
}
}

ScreenRecorder::ScreenRecorder(bool useLegacyRecorder) :
    _impl(NULL),
    _implFallback(NULL),
    _recordShm(NULL),
    _cursorShm(NULL),
    _client(NULL)
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
}

bool ScreenRecorder::StartRecord(xstream_t* cmd) {
    if (_impl != NULL) {
        return StartRecordNew(cmd);
    }
    else if (_implFallback != NULL) {
        return StartRecordLegacy(cmd);
    }
    return false;
}

bool ScreenRecorder::ParseStartRecordParams(xstream_t* cmd, RecordStartParams* params) {
    if (cmd == NULL || params == NULL) {
        return false;
    }

    params->monitorIndex = xstream_readInt32(cmd);
    params->width = xstream_readInt32(cmd);
    params->height = xstream_readInt32(cmd);
    params->framerate = xstream_readInt32(cmd);
    params->recordFormat = xstream_readInt32(cmd);
    params->useVirtualMon = xstream_readInt32(cmd);

    (void)params->monitorIndex; // unused yet

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

    if (params->width <= 0 || params->height <= 0) {
        NSLog(@"[ScreenRecorder::StartRecord] invalid request. width: %d height: %d", params->width, params->height);
        return false;
    }

    if (params->width > 10000 || params->height > 10000) {
        NSLog(@"[ScreenRecorder::StartRecord] invalid request. too large display width: %d height: %d", params->width, params->height);
        return false;
    }

    params->width &= ~0x1;
    params->height &= ~0x1;

    // 절전 모드는 아니지만, 디스플레이가 꺼져 있는 경우 문제가 발생할 수 있음.
    // 따라서 먼저 디스플레이를 잠시 깨워준다. (가상 디스플레이 사용중일때는 다시 꺼질 예정)
    VirtualMonitor::WakeupDisplay();

    return true;
}

bool ScreenRecorder::PrepareRecordResources(const RecordStartParams* params) {
    if (params == NULL) {
        return false;
    }

    if (CreateRecordShm(params->width, params->height, params->framerate) == false) {
        NSLog(@"[ScreenRecorder::StartRecord] could not create record shm");
        return false;
    }

    if (CreateCursorShm() == false) {
        NSLog(@"[ScreenRecorder::StartRecord] could not create cursor shm");
        DestroyRecordShm();
        return false;
    }

    return true;
}

bool ScreenRecorder::ResolveDisplayForNewRecorder(const RecordStartParams* params, void** displayOut) {
    if (params == NULL || displayOut == NULL) {
        return false;
    }

    *displayOut = NULL;

    SCDisplay* display = nil;
    if (params->useVirtualMon != 0) {
        int monId = _virtualMonitor.Create(params->width, params->height);
        if (monId == -1) {
            _virtualMonitor.RestoreOtherMonitors();

            display = _GET_DISPLAY_USING_INDEX(0);
            if (display == nil) {
                NSLog(@"[ScreenRecorder::StartRecord] display is nil (virtual desktop mod fallback)");
                return false;
            }

            _inputHandler.UpdateDisplayRes((int)display.width, (int)display.height, params->width, params->height);
        }
        else {
            display = _GET_DISPLAY_USING_ID(monId);
            if (display == nil) {
                NSLog(@"[ScreenRecorder::StartRecord] display is nil (virtual desktop mod. displayid %d)", monId);
                return false;
            }

            // macOS 12 에서 가상 디스플레이의 width, height 가 1로 오는 증상이 발생...
            // 가상 디스플레이는 클라이언트의 해상도를 따라가므로 동일하게 설정
            int div = 1;
            if (_virtualMonitor.IsRetina() == true) {
                div = 2;
            }
            
            _inputHandler.UpdateDisplayRes(params->width / div, params->height / div, params->width, params->height);
        }
    }
    else {
        display = _GET_DISPLAY_USING_INDEX(0);
        if (display == nil) {
            NSLog(@"[ScreenRecorder::StartRecord] display is nil (no virtual desktop mod)");
            return false;
        }

        _inputHandler.UpdateDisplayRes((int)display.width, (int)display.height, params->width, params->height);
    }
    
    // hack
    DisplayUtils::WaitDisplayOnlineState(display.displayID, true, 10000);

    *displayOut = (__bridge_retained void*)display;
    return true;
}

bool ScreenRecorder::ResolveDisplayForLegacyRecorder(const RecordStartParams* params, int* displayIdOut) {
    if (params == NULL || displayIdOut == NULL) {
        return false;
    }

    int displayId = -1;
    if (params->useVirtualMon != 0) {
        displayId = _virtualMonitor.Create(params->width, params->height);
        if (displayId == -1) {
            _virtualMonitor.RestoreOtherMonitors();
            displayId = CGMainDisplayID();
        }

        // macOS 12 에서 가상 디스플레이의 width, height 가 1로 오는 증상이 발생...
        // 가상 디스플레이는 클라이언트의 해상도를 따라가므로 동일하게 설정
        
        int div = 1;
        if (_virtualMonitor.IsRetina() == true) {
            div = 2;
        }
        
        _inputHandler.UpdateDisplayRes(params->width / div, params->height / div, params->width, params->height);
    }
    else {
        displayId = CGMainDisplayID();
        CGRect rect = CGDisplayBounds(displayId);
        _inputHandler.UpdateDisplayRes((int)rect.size.width, (int)rect.size.height, params->width, params->height);
    }
    
    // hack
    DisplayUtils::WaitDisplayOnlineState(displayId, true, 10000);
    
    NSLog(@"[testtest] displayid %d", displayId);

    *displayIdOut = displayId;
    return true;
}

bool ScreenRecorder::StartRecordNew(xstream_t* cmd) {
    RecordStartParams params = {};
    if (ParseStartRecordParams(cmd, &params) == false) {
        return false;
    }

    void* displayObj = NULL;
    if (ResolveDisplayForNewRecorder(&params, &displayObj) == false) {
        return false;
    }
    SCDisplay* display = (__bridge_transfer SCDisplay*)displayObj;

    if (PrepareRecordResources(&params) == false) {
        return false;
    }

    ScreenRecorderImpl* impl = (__bridge ScreenRecorderImpl*)_impl;
    on_record_data recordDataCb = HandleBGRA32RecordData;
    if (params.recordFormat == OSXRDP_RECORDFORMAT_NV12_PACKED) {
        recordDataCb = HandleNV12PackedRecordData;
    }
    else if (params.recordFormat == OSXRDP_RECORDFORMAT_NV12_ALIGNED) {
        recordDataCb = HandleNV12AlignedRecordData;
    }
    else if (params.recordFormat == OSXRDP_RECORDFORMAT_RFX) {
        recordDataCb = HandleRFXRecordData;
    }

    [impl initializeWithDisplay:display
                    RecordWidth:params.width RecordHeight:params.height
                    RecordFramerate:params.framerate RecordFormat:params.recordFormat
                    RecordDataCallback:recordDataCb RecordDataCallbackUserData:this
                    RecordCmdCallback:HandleRecordCommand RecordCmdCallbackUserData:this];

    if ([impl start] == NO) {
        DestroyRecordShm();
        DestroyCursorShm();
        return false;
    }

    return true;
}

bool ScreenRecorder::StartRecordLegacy(xstream_t* cmd) {
    RecordStartParams params = {};
    if (ParseStartRecordParams(cmd, &params) == false) {
        return false;
    }

    int displayId = -1;
    if (ResolveDisplayForLegacyRecorder(&params, &displayId) == false) {
        return false;
    }

    if (PrepareRecordResources(&params) == false) {
        return false;
    }

    ScreenRecorderFallbackImpl* fallbackImpl = (__bridge ScreenRecorderFallbackImpl*)_implFallback;
    on_record_data_fb recordDataCb = HandleFallbackBGRA32RecordData;
    if (params.recordFormat == OSXRDP_RECORDFORMAT_NV12_PACKED) {
        recordDataCb = HandleFallbackNV12PackedRecordData;
    }
    else if (params.recordFormat == OSXRDP_RECORDFORMAT_NV12_ALIGNED) {
        recordDataCb = HandleFallbackNV12AlignedRecordData;
    }
    else if (params.recordFormat == OSXRDP_RECORDFORMAT_RFX) {
        recordDataCb = HandleFallbackRFXRecordData;
    }

    [fallbackImpl initializeWithDisplayId:displayId
                    RecordWidth:params.width RecordHeight:params.height
                    RecordFramerate:params.framerate RecordFormat:params.recordFormat
                    RecordDataCallback:recordDataCb RecordDataCallbackUserData:this
                    RecordCmdCallback:HandleRecordCommand RecordCmdCallbackUserData:this];

    if ([fallbackImpl start] == NO) {
        DestroyRecordShm();
        DestroyCursorShm();
        return false;
    }

    return true;
}

bool ScreenRecorder::CreateRecordShm(int width, int height, int framerate) {
    if (_recordShm != NULL) {
        NSLog(@"[ScreenRecorder::CreateRecordShm] recordShm is already exists.");
        
        return false;
    }
    
    // todo : format 마다 정확한 크기 설정하기
    int rawDataSize = width * height * 5 + (sizeof(size_t) * 2);
    
    char shm_name[512];
    if (get_object_name_by_sessionid("/osxrdpshm", shm_name, 512, is_root_process()) == 0) {
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

bool ScreenRecorder::CreateCursorShm() {
    if (_cursorShm != NULL) {
        NSLog(@"[ScreenRecorder::CreateCursorShm] cursorShm is already exists.");
        
        return false;
    }
    
    char shm_name[512];
    if (get_object_name_by_sessionid("/osxrdpcursorshm", shm_name, 512, is_root_process()) == 0) {
        return false;
    }

    _cursorShm = xshm_create(shm_name, sizeof(cursor_data_t));
    if (_cursorShm == NULL) {
        NSLog(@"[ScreenRecorder::CreateCursorShm] xshm_create failed.");
        
        return false;
    }
    
    memset(_cursorShm->mem, 0x00, sizeof(cursor_data_t));
    
    return true;
}

void ScreenRecorder::DestroyCursorShm() {
    if (_cursorShm == NULL) {
        return;
    }
    
    xshm_close(_cursorShm);
    xshm_destroy(_cursorShm);
    _cursorShm = NULL;
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
    DestroyCursorShm();
}

void ScreenRecorder::HandleCommand(xipc_t* client, xstream_t* cmd) {
    if (cmd == NULL) return;
    
    int packetType = xstream_readInt32(cmd);
    switch (packetType) {
        case OSXRDP_PACKETTYPE_REQ_SCREEN: {
            _client = client;
            bool re = StartRecord(cmd);
            
            NSLog(@"[ScreenRecorder::HandleCommand] start record. result %d", re);

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
            NSLog(@"[ScreenRecorder::HandleCommand] stop record");
            
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

void ScreenRecorder::SendDisconnectMsgToClient() {
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

void* ScreenRecorder::GetDisplay(int unused) {
    __block SCDisplay* found = nil;
    
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    
    // ????? macOS 12, 13, 14 모두 잠금화면에서 이것을 호출하면 hang 이 발생함.... 뭐지 --> 아마 이때 NSError 값이 있었던것 같음
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

bool ScreenRecorder::AcquireFrameSlot(ScreenRecorder* recorder, screenrecord_shm_t** recordInfoOut, screenrecord_frame** frameOut, char** dataOut, unsigned int* writePosOut) {
    if (recorder == NULL || recorder->_recordShm == NULL || recorder->_recordShm->mem == NULL) {
        return false;
    }

    if (recordInfoOut == NULL || frameOut == NULL || dataOut == NULL || writePosOut == NULL) {
        return false;
    }

    screenrecord_shm_t* recordInfo = (screenrecord_shm_t*)recorder->_recordShm->mem;
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

void ScreenRecorder::CommitFrameSlot(ScreenRecorder* recorder, screenrecord_shm_t* recordInfo, unsigned int writePos) {
    if (recorder == NULL || recordInfo == NULL) {
        return;
    }

    atomic_store_explicit(&recordInfo->write_pos, writePos + 1, memory_order_release);

    if (recorder->_client != NULL) {
        int dummy = OSXRDP_CMDTYPE_DUMMY;
        xipc_send_data(recorder->_client, (void*)&dummy, sizeof(int));
    }
}

bool ScreenRecorder::CopyNV12PackedFrame(void* imageBufferRef, char* screenrecord_data, int* widthOut, int* heightOut) {
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

bool ScreenRecorder::CopyNV12AlignedFrame(void* imageBufferRef, char* screenrecord_data, int* widthOut, int* heightOut) {
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

bool ScreenRecorder::CopyYUV444Frame(void* imageBufferRef, char* screenrecord_data, int* widthOut, int* heightOut) {
    if (imageBufferRef == NULL || screenrecord_data == NULL || widthOut == NULL || heightOut == NULL) {
        return false;
    }

    CVImageBufferRef imageBuffer = (CVImageBufferRef)imageBufferRef;
    size_t width = CVPixelBufferGetWidth(imageBuffer);
    size_t height = CVPixelBufferGetHeight(imageBuffer);
    if (width == 0 || height == 0) {
        return false;
    }

    const OSType pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer);
    if (pixelFormat != kCVPixelFormatType_32BGRA) {
        return false;
    }

    uint8_t* srcBase = (uint8_t*)CVPixelBufferGetBaseAddress(imageBuffer);
    size_t srcStride = CVPixelBufferGetBytesPerRow(imageBuffer);
    if (srcBase == NULL) {
        return false;
    }

    const size_t tileCols = (width + 63) / 64;
    const size_t tileRows = (height + 63) / 64;
    const size_t imgSize = (size_t)tileCols * (size_t)tileRows * 16384;
    
    memcpy(screenrecord_data, &imgSize, sizeof(size_t));

    uint8_t* dst = (uint8_t*)screenrecord_data + sizeof(size_t);
    if (ConvertBGRA8888ToRFXPlanarTilesSHM(srcBase, srcStride, (int)width, (int)height, dst) == false) {
        return false;
    }

    *widthOut = (int)width;
    *heightOut = (int)height;
    return true;
}

bool ScreenRecorder::CopyBGRA32Frame(void* imageBufferRef, char* screenrecord_data, int* widthOut, int* heightOut) {
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

void ScreenRecorder::PopulateDirtyRectsFromSampleBuffer(void* sampleBufferRef, int width, int height, screenrecord_frame* current_frame) {
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

void ScreenRecorder::PopulateDirtyRectsFromArray(const CGRect* dirtyRects, int dirtyRectsCnt, int width, int height, screenrecord_frame* current_frame) {
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

    CGRect tmp;
    for (int i = 0; i < current_frame->dirtyCount; i++) {
        memcpy(&tmp, &dirtyRects[i], sizeof(CGRect));
        ProcessDirtyArea(&tmp, width, height, &(current_frame->dirtys[i]));
    }
}

void ScreenRecorder::HandleNV12PackedRecordData(void* sampleBuffer, void* imgBuffer, void* userData) {
    if (sampleBuffer == NULL || userData == NULL) return;

    ScreenRecorder* recorder = (ScreenRecorder*)userData;

    screenrecord_shm_t* recordInfo = NULL;
    screenrecord_frame* slot = NULL;
    char* screenrecord_data = NULL;
    unsigned int writePos = 0;
    if (AcquireFrameSlot(recorder, &recordInfo, &slot, &screenrecord_data, &writePos) == false) {
        return;
    }

    HandleNV12PackedDirtyArea(sampleBuffer, imgBuffer, slot, screenrecord_data);
    CommitFrameSlot(recorder, recordInfo, writePos);
}

void ScreenRecorder::HandleNV12AlignedRecordData(void* sampleBuffer, void* imgBuffer, void* userData) {
    if (sampleBuffer == NULL || userData == NULL) return;

    ScreenRecorder* recorder = (ScreenRecorder*)userData;

    screenrecord_shm_t* recordInfo = NULL;
    screenrecord_frame* slot = NULL;
    char* screenrecord_data = NULL;
    unsigned int writePos = 0;
    if (AcquireFrameSlot(recorder, &recordInfo, &slot, &screenrecord_data, &writePos) == false) {
        return;
    }

    HandleNV12AlignedDirtyArea(sampleBuffer, imgBuffer, slot, screenrecord_data);
    CommitFrameSlot(recorder, recordInfo, writePos);
}

void ScreenRecorder::HandleBGRA32RecordData(void* sampleBuffer, void* imgBuffer, void* userData) {
    if (sampleBuffer == NULL || userData == NULL) return;

    ScreenRecorder* recorder = (ScreenRecorder*)userData;

    screenrecord_shm_t* recordInfo = NULL;
    screenrecord_frame* slot = NULL;
    char* screenrecord_data = NULL;
    unsigned int writePos = 0;
    if (AcquireFrameSlot(recorder, &recordInfo, &slot, &screenrecord_data, &writePos) == false) {
        return;
    }

    HandleBGRA32DirtyArea(sampleBuffer, imgBuffer, slot, screenrecord_data);
    CommitFrameSlot(recorder, recordInfo, writePos);
}

void ScreenRecorder::HandleRFXRecordData(void* sampleBuffer, void* imgBuffer, void* userData) {
    if (sampleBuffer == NULL || userData == NULL) return;

    ScreenRecorder* recorder = (ScreenRecorder*)userData;

    screenrecord_shm_t* recordInfo = NULL;
    screenrecord_frame* slot = NULL;
    char* screenrecord_data = NULL;
    unsigned int writePos = 0;
    if (AcquireFrameSlot(recorder, &recordInfo, &slot, &screenrecord_data, &writePos) == false) {
        return;
    }

    HandleRFXDirtyArea(sampleBuffer, imgBuffer, slot, screenrecord_data);
    CommitFrameSlot(recorder, recordInfo, writePos);
}

void ScreenRecorder::HandleNV12PackedDirtyArea(void* sampleBuffer, void* imgBuffer, screenrecord_frame* current_frame, char* screenrecord_data) {
    int width = 0;
    int height = 0;
    if (CopyNV12PackedFrame(imgBuffer, screenrecord_data, &width, &height) == false) {
        return;
    }

    PopulateDirtyRectsFromSampleBuffer(sampleBuffer, width, height, current_frame);
}

void ScreenRecorder::HandleNV12AlignedDirtyArea(void* sampleBuffer, void* imgBuffer, screenrecord_frame* current_frame, char* screenrecord_data) {
    int width = 0;
    int height = 0;
    if (CopyNV12AlignedFrame(imgBuffer, screenrecord_data, &width, &height) == false) {
        return;
    }

    PopulateDirtyRectsFromSampleBuffer(sampleBuffer, width, height, current_frame);
}

void ScreenRecorder::HandleBGRA32DirtyArea(void* sampleBuffer, void* imgBuffer, screenrecord_frame* current_frame, char* screenrecord_data) {
    int width = 0;
    int height = 0;
    if (CopyBGRA32Frame(imgBuffer, screenrecord_data, &width, &height) == false) {
        return;
    }

    PopulateDirtyRectsFromSampleBuffer(sampleBuffer, width, height, current_frame);
}

void ScreenRecorder::HandleRFXDirtyArea(void* sampleBuffer, void* imgBuffer, screenrecord_frame* current_frame, char* screenrecord_data) {
    int width = 0;
    int height = 0;
    if (CopyYUV444Frame(imgBuffer, screenrecord_data, &width, &height) == false) {
        return;
    }

    PopulateDirtyRectsFromSampleBuffer(sampleBuffer, width, height, current_frame);
}

void ScreenRecorder::HandleFallbackNV12PackedRecordData(void* pixelBuffer, const CGRect* dirtyRects, int dirtyRectsCnt, void* userData){
    if (pixelBuffer == NULL || userData == NULL) return;

    ScreenRecorder* recorder = (ScreenRecorder*)userData;

    screenrecord_shm_t* recordInfo = NULL;
    screenrecord_frame* slot = NULL;
    char* screenrecord_data = NULL;
    unsigned int writePos = 0;
    if (AcquireFrameSlot(recorder, &recordInfo, &slot, &screenrecord_data, &writePos) == false) {
        return;
    }

    HandleFallbackNV12PackedDirtyArea(pixelBuffer, slot, dirtyRects, dirtyRectsCnt, screenrecord_data);
    CommitFrameSlot(recorder, recordInfo, writePos);
}

void ScreenRecorder::HandleFallbackNV12AlignedRecordData(void* pixelBuffer, const CGRect* dirtyRects, int dirtyRectsCnt, void* userData){
    if (pixelBuffer == NULL || userData == NULL) return;

    ScreenRecorder* recorder = (ScreenRecorder*)userData;

    screenrecord_shm_t* recordInfo = NULL;
    screenrecord_frame* slot = NULL;
    char* screenrecord_data = NULL;
    unsigned int writePos = 0;
    if (AcquireFrameSlot(recorder, &recordInfo, &slot, &screenrecord_data, &writePos) == false) {
        return;
    }

    HandleFallbackNV12AlignedDirtyArea(pixelBuffer, slot, dirtyRects, dirtyRectsCnt, screenrecord_data);
    CommitFrameSlot(recorder, recordInfo, writePos);
}

void ScreenRecorder::HandleFallbackNV12PackedDirtyArea(void* pixelBuffer, screenrecord_frame* current_frame, const CGRect* dirtyRects, int dirtyRectsCnt, char* screenrecord_data) {
    int width = 0;
    int height = 0;
    if (CopyNV12PackedFrame(pixelBuffer, screenrecord_data, &width, &height) == false) {
        return;
    }

    PopulateDirtyRectsFromArray(dirtyRects, dirtyRectsCnt, width, height, current_frame);
}

void ScreenRecorder::HandleFallbackNV12AlignedDirtyArea(void* pixelBuffer, screenrecord_frame* current_frame, const CGRect* dirtyRects, int dirtyRectsCnt, char* screenrecord_data) {
    int width = 0;
    int height = 0;
    if (CopyNV12AlignedFrame(pixelBuffer, screenrecord_data, &width, &height) == false) {
        return;
    }

    PopulateDirtyRectsFromArray(dirtyRects, dirtyRectsCnt, width, height, current_frame);
}

void ScreenRecorder::HandleFallbackBGRA32RecordData(void* pixelBuffer, const CGRect* dirtyRects, int dirtyRectsCnt, void* userData){
    if (pixelBuffer == NULL || userData == NULL) return;

    ScreenRecorder* recorder = (ScreenRecorder*)userData;

    screenrecord_shm_t* recordInfo = NULL;
    screenrecord_frame* slot = NULL;
    char* screenrecord_data = NULL;
    unsigned int writePos = 0;
    if (AcquireFrameSlot(recorder, &recordInfo, &slot, &screenrecord_data, &writePos) == false) {
        return;
    }

    HandleFallbackBGRA32DirtyArea(pixelBuffer, slot, dirtyRects, dirtyRectsCnt, screenrecord_data);
    CommitFrameSlot(recorder, recordInfo, writePos);
}

void ScreenRecorder::HandleFallbackRFXRecordData(void* pixelBuffer, const CGRect* dirtyRects, int dirtyRectsCnt, void* userData){
    if (pixelBuffer == NULL || userData == NULL) return;

    ScreenRecorder* recorder = (ScreenRecorder*)userData;

    screenrecord_shm_t* recordInfo = NULL;
    screenrecord_frame* slot = NULL;
    char* screenrecord_data = NULL;
    unsigned int writePos = 0;
    if (AcquireFrameSlot(recorder, &recordInfo, &slot, &screenrecord_data, &writePos) == false) {
        return;
    }

    HandleFallbackRFXDirtyArea(pixelBuffer, slot, dirtyRects, dirtyRectsCnt, screenrecord_data);
    CommitFrameSlot(recorder, recordInfo, writePos);
}

void ScreenRecorder::HandleFallbackBGRA32DirtyArea(void* pixelBuffer, screenrecord_frame* current_frame, const CGRect* dirtyRects, int dirtyRectsCnt, char* screenrecord_data) {
    int width = 0;
    int height = 0;
    if (CopyBGRA32Frame(pixelBuffer, screenrecord_data, &width, &height) == false) {
        return;
    }

    PopulateDirtyRectsFromArray(dirtyRects, dirtyRectsCnt, width, height, current_frame);
}

void ScreenRecorder::HandleFallbackRFXDirtyArea(void* pixelBuffer, screenrecord_frame* current_frame, const CGRect* dirtyRects, int dirtyRectsCnt, char* screenrecord_data) {
    int width = 0;
    int height = 0;
    if (CopyYUV444Frame(pixelBuffer, screenrecord_data, &width, &height) == false) {
        return;
    }

    PopulateDirtyRectsFromArray(dirtyRects, dirtyRectsCnt, width, height, current_frame);
}

inline void ScreenRecorder::ProcessDirtyArea(const CGRect* rect, int limX, int limY, struct RECT* dst) {
    const short orgX = rect->origin.x;
    const short orgY = rect->origin.y;
    const short orgW = rect->size.width;
    const short orgH = rect->size.height;

    // padding 추가 (이것이 없을 경우 화면 해상도가 1:1 이 아닌 경우 창의 끝부분 잔상이 남는 경우가 있음)
    int x0 = (int)orgX - 2;
    int y0 = (int)orgY - 2;
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
