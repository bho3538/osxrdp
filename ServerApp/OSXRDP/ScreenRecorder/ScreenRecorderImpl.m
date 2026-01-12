#import "ScreenRecorderImpl.h"

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#include "osxrdp/packet.h"

@implementation ScreenRecorderImpl {
    SCContentFilter* _recordFilter;
    SCStreamConfiguration* _recordConfig;
    dispatch_queue_t _recordQue;
    SCStream* _recordStream;
    on_record_data _recordCb;
    on_record_cmd _recordCmdCb;
    void* _recordCbUserData;
    void* _recordCmdCbUserData;
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _recordFilter = nil;
        _recordConfig = nil;
        _recordQue = nil;
        _recordStream = nil;
        _recordCb = NULL;
        _recordCbUserData = NULL;
    }
    
    return self;
}

- (void)initializeWithDisplay:(SCDisplay*)display
            RecordWidth:(int)width
            RecordHeight:(int)height
            RecordFramerate:(int)framerate
            RecordFormat:(int)recordFormat
            RecordDataCallback:(on_record_data)recordCb
            RecordDataCallbackUserData:(void*)userData
            RecordCmdCallback:(on_record_cmd)recordCmdCb
            RecordCmdCallbackUserData:(void*)userData2 {
    if (display == nil) return;
    
    _recordFilter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
    if (_recordFilter == nil) return;
    
    // 녹화 설정 (해상도, 프레임 등)
    _recordConfig = [[SCStreamConfiguration alloc] init];
    _recordConfig.width = width;
    _recordConfig.height = height;
    _recordConfig.queueDepth = 3;
    // 이 값이 없으면 물빠진 색감이 나옴
    _recordConfig.colorSpaceName = kCGColorSpaceSRGB;
    
    if (recordFormat == OSXRDP_RECORDFORMAT_NV12) {
        _recordConfig.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    }
    else {
        _recordConfig.pixelFormat = kCVPixelFormatType_32BGRA;
    }
    
    _recordConfig.showsCursor = NO;
    // 이것이 없는 구형 os 는 어떻게 확인하지..? --> 구형 os 는 screenrecorderfallback 을 사용하도록 함.
    if (@available(macOS 14.0,*)) {
        _recordConfig.preservesAspectRatio = NO;
    }
    _recordConfig.minimumFrameInterval = CMTimeMake(1, framerate);
    
    // 녹화 큐 설정
    _recordQue = dispatch_queue_create("osxrdp.record", DISPATCH_QUEUE_SERIAL);
    
    // 녹화 데이터 콜백 (인코딩 한 후 이를 전달하기 위해)
    _recordCb = recordCb;
    _recordCbUserData = userData;
    
    _recordCmdCb = recordCmdCb;
    _recordCmdCbUserData = userData2;
}

- (BOOL)start {
    
    if (_recordFilter == nil) {
        NSLog(@"[ScreenRecorderImpl::start] recordFilter is NULL\n");
        
        return FALSE;
    }
    
    if (_recordConfig == nil) {
        NSLog(@"[ScreenRecorderImpl::start] recordConfig is NULL\n");
        
        return FALSE;
    }
    
    if (_recordQue == nil) {
        NSLog(@"[ScreenRecorderImpl::start] recordQue is NULL\n");
        
        return FALSE;
    }
    
    _recordStream = [[SCStream alloc] initWithFilter:_recordFilter configuration:_recordConfig delegate:self];
    
    NSError* err = nil;
    [_recordStream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:_recordQue error:&err];
    
    if (err != nil) {
        NSLog(@"[ScreenRecorderImpl::start] addStreamOutput failed. %ld\n", err.code);
        
        return FALSE;
    }
    
    [_recordStream startCaptureWithCompletionHandler:nil];
    
    NSLog(@"[ScreenRecorderImpl::start] Start Record\n");

    return TRUE;
}

- (BOOL)stop {
    if (_recordStream == nil) return YES;
    
    __block NSError* stopError = nil;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [_recordStream stopCaptureWithCompletionHandler:^(NSError* _Nullable err) {
        stopError = err;
        
        dispatch_semaphore_signal(sema);
    }];
    
    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
    
    if (stopError != nil) {
        NSLog(@"[ScreenRecorderImpl::stop] Stop Record failed. %ld\n", stopError.code);
        
        return NO;
    }
    else {
        NSError* err = nil;
        [_recordStream removeStreamOutput:self type:SCStreamOutputTypeScreen error:&err];
        _recordStream = nil;
        _recordFilter = nil;
        _recordConfig = nil;

        NSLog(@"[ScreenRecorderImpl::stop] Stop Record\n");
        
        return YES;
    }
    
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    
    // 1. ImageBuffer 추출 (CVPixelBufferRef와 동일)
    CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (pixelBuffer == NULL) {
        return;
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        
    // 콜백 호출 (osxup 로 화면 데이터 전송)
    _recordCb(sampleBuffer, pixelBuffer, _recordCbUserData);

    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    // 녹화 정지 요청
    _recordCmdCb(1, _recordCmdCbUserData);
}

@end
