#import "ScreenRecorderFallbackImpl.h"
#include "osxrdp/packet.h"

@implementation ScreenRecorderFallbackImpl {
    CGDisplayStreamRef _displayStream;
    NSDictionary* _recordConfig;
    dispatch_queue_t _recordQue;
    on_record_data_fb _recordCb;
    on_record_cmd _recordCmdCb;
    void* _recordCbUserData;
    void* _recordCmdCbUserData;
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

- (void)initializeWithDisplay:(SCDisplay*)display
            RecordWidth:(int)width
            RecordHeight:(int)height
            RecordFramerate:(int)framerate
            RecordFormat:(int)recordFormat
            RecordDataCallback:(on_record_data_fb)recordCb
            RecordDataCallbackUserData:(void*)userData
            RecordCmdCallback:(on_record_cmd)recordCmdCb
            RecordCmdCallbackUserData:(void*)userData2 {
    
    if (display == nil) return;
    
    CGRect destRect = CGRectMake(0, 0, width, height);
    CFDictionaryRef destRectDict = CGRectCreateDictionaryRepresentation(destRect);
    
    CGColorSpaceRef sRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);

    _recordConfig = @{
        (__bridge NSString*)kCGDisplayStreamShowCursor : @NO,
        (__bridge NSString*)kCGDisplayStreamQueueDepth : @3,
        (__bridge NSString*)kCGDisplayStreamMinimumFrameTime : @0.0167,     // 60fps
        (__bridge NSString*)kCGDisplayStreamDestinationRect : (__bridge_transfer NSDictionary*)destRectDict,
        (__bridge NSString*)kCGDisplayStreamPreserveAspectRatio : @NO,      // 비율 무시하고 녹화 (늘리기)
        (__bridge NSString*)kCGDisplayStreamColorSpace : (__bridge id)sRGB, // 이 설정이 없으면 물빠진 색감이 나옴
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
    
    _recordQue = dispatch_queue_create("osxrdp.fallback_record", DISPATCH_QUEUE_SERIAL);
    
    int format = kCVPixelFormatType_32BGRA; // 일반 bitmap
    if (recordFormat == OSXRDP_RECORDFORMAT_NV12) {
        format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange; // h264
    }
    
    _displayStream = CGDisplayStreamCreateWithDispatchQueue([display displayID], width, height, format, (__bridge CFDictionaryRef)_recordConfig, _recordQue, handler);
    
    _recordCb = recordCb;
    _recordCbUserData = userData;
    _recordCmdCb = recordCmdCb;
    _recordCmdCbUserData = userData2;
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
    
    CGError err = CGDisplayStreamStart(_displayStream);
    if (err != kCGErrorSuccess) {
        NSLog(@"[ScreenRecorderFallbackImpl::start] Failed to start stream: %d\n", err);
        CFRelease(_displayStream);
        _displayStream = NULL;
        return FALSE;
    }
    
    NSLog(@"[ScreenRecorderFallbackImpl::start] Start Record\n");
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
    _recordCb(pixelBuffer, dirtyRects, (int)dirtyRectsCnt, _recordCbUserData);
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    
    CVPixelBufferRelease(pixelBuffer);
}

- (void)processStreamStopped {
    _recordCmdCb(1, _recordCmdCbUserData);
}

@end
