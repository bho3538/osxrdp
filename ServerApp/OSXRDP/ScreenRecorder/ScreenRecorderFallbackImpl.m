#import "ScreenRecorderFallbackImpl.h"
#include "osxrdp/packet.h"

@implementation ScreenRecorderFallbackImpl {
    CGDisplayStreamRef _displayStream;
    NSDictionary* _recordConfig;
    dispatch_queue_t _recordQue;
    on_record_data _recordCb;
    on_record_cmd _recordCmdCb;
    void* _recordCbUserData;
    void* _recordCmdCbUserData;
    int _displayIdx;
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _displayStream = NULL;
        _recordConfig = NULL;
        _recordQue = nil;
        _recordCb = NULL;
        _recordCbUserData = NULL;
        _recordCmdCb = NULL;
        _recordCmdCbUserData = NULL;
    }
    return self;
}

- (void)initializeWithDisplayId:(int)displayId
            DisplayIndex:(int)displayIdx
            RecordWidth:(int)width
            RecordHeight:(int)height
            RecordFramerate:(int)framerate
            RecordFormat:(int)recordFormat
            RecordDataCallback:(on_record_data)recordCb
            RecordDataCallbackUserData:(void*)userData
            RecordCmdCallback:(on_record_cmd)recordCmdCb
            RecordCmdCallbackUserData:(void*)userData2 {
    
    CGRect destRect = CGRectMake(0, 0, width, height);
    CFDictionaryRef destRectDict = CGRectCreateDictionaryRepresentation(destRect);
    
    CGColorSpaceRef sRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    
    float frameTime = 1.0f / framerate;

    _recordConfig = @{
        (__bridge NSString*)kCGDisplayStreamShowCursor : @NO,
        (__bridge NSString*)kCGDisplayStreamQueueDepth : @3,
        (__bridge NSString*)kCGDisplayStreamMinimumFrameTime : @(frameTime),
        (__bridge NSString*)kCGDisplayStreamDestinationRect : (__bridge_transfer NSDictionary*)destRectDict,
        (__bridge NSString*)kCGDisplayStreamPreserveAspectRatio : @NO,      // 비율 무시하고 녹화 (늘리기)
        //(__bridge NSString*)kCGDisplayStreamColorSpace : (__bridge id)sRGB, // 이 설정이 없으면 물빠진 색감이 나옴
    };
    
    CGColorSpaceRelease(sRGB);

    CGDisplayStreamFrameAvailableHandler handler = ^(CGDisplayStreamFrameStatus status,
                                                     uint64_t displayTime,
                                                     IOSurfaceRef frameSurface,
                                                     CGDisplayStreamUpdateRef updateRef) {
        if (status == kCGDisplayStreamFrameStatusFrameComplete && frameSurface != NULL) {
            // 녹화 콜백
            [self processFrame:frameSurface displayTime:displayTime update:updateRef];
        }
        else if (status == kCGDisplayStreamFrameStatusStopped) {
            // 녹화 상태 콜백
            [self processStreamStopped];
        }
    };
    
    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
    _recordQue = dispatch_queue_create("osxrdp.fallback_record", attr);
    
    int format = kCVPixelFormatType_32BGRA; // 일반 bitmap
    if (recordFormat == OSXRDP_RECORDFORMAT_NV12_PACKED || recordFormat == OSXRDP_RECORDFORMAT_NV12_ALIGNED) {
        format = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange; // h264
    }
    else if (recordFormat == OSXRDP_RECORDFORMAT_RFX) {
        format = kCVPixelFormatType_32BGRA; // rfx (BGRA 캡처 후 상위에서 YUV444 변환)
    }
    
    _displayStream = CGDisplayStreamCreateWithDispatchQueue(displayId, width, height, format, (__bridge CFDictionaryRef)_recordConfig, _recordQue, handler);
    if (_displayStream == NULL) {
        // ????????
        usleep(5000);
        _displayStream = CGDisplayStreamCreateWithDispatchQueue(displayId, width, height, format, (__bridge CFDictionaryRef)_recordConfig, _recordQue, handler);
    }
    
    _recordCb = recordCb;
    _recordCbUserData = userData;
    _recordCmdCb = recordCmdCb;
    _recordCmdCbUserData = userData2;
    _displayIdx = displayIdx;
}

- (BOOL)start {
    if (_recordQue == nil) {
         NSLog(@"[ScreenRecorderFallbackImpl::start] recordQue is NULL\n");
         return FALSE;
    }
    
    if (_displayStream == NULL) {
        NSLog(@"[ScreenRecorderFallbackImpl::start] displayStream is NULL\n");
        return FALSE;
    }
    
    NSLog(@"[ScreenRecorderFallbackImpl::start] before start record\n");
    
    CGError err = CGDisplayStreamStart(_displayStream);
    if (err != kCGErrorSuccess) {
        NSLog(@"[ScreenRecorderFallbackImpl::start] Failed to start stream: %d\n", err);
        CFRelease(_displayStream);
        _displayStream = NULL;
        return FALSE;
    }
    
    NSLog(@"[ScreenRecorderFallbackImpl::start] start record\n");
    return TRUE;
}

- (BOOL)stop {
    if (_displayStream == NULL) return YES;
    
    CGDisplayStreamStop(_displayStream);
    
    if (_recordQue) {
        dispatch_sync(_recordQue, ^{});
    }
    
    CFRelease(_displayStream);
    _displayStream = NULL;
    
    NSLog(@"[ScreenRecorderFallbackImpl::stop] Stop Record\n");
    
    return YES;
}

- (void)processFrame:(IOSurfaceRef)ioSurface displayTime:(uint64_t)displayTime update:(CGDisplayStreamUpdateRef)updateRef {
    if (_recordCb == NULL) return;

    CVPixelBufferRef pixelBuffer = NULL;
    
    CVReturn cvErr = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, ioSurface, NULL, &pixelBuffer);
    if (cvErr != kCVReturnSuccess) {
        return;
    }
    
    // dirty 영역을 조회
    size_t dirtyRectsCnt= 0;
    const CGRect* dirtyRects = CGDisplayStreamUpdateGetRects(updateRef, kCGDisplayStreamUpdateDirtyRects, &dirtyRectsCnt);
    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    
    // 녹화 콜백 전달
    _recordCb(pixelBuffer, dirtyRects, (int)dirtyRectsCnt, _recordCbUserData, _displayIdx);
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    
    CVPixelBufferRelease(pixelBuffer);
}

- (void)processStreamStopped {
    _recordCmdCb(1, _recordCmdCbUserData);
}

@end
