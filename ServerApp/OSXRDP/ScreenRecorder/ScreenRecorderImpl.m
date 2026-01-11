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
    
    // macOS 과거 버전에서는 (12 버전에서 확인) screencapturekit 에 버그가 있는것 같음.
    // 이를 우회하기 위해 내 앱 (osxrdp)의 창은 캡쳐하지 않도록 더미로 넘기기
    // todo : 내 창을 찾지 못한 경우 1x1 투명 더미 창을 만들어야 하나??
    // https://federicoterzi.com/blog/screencapturekit-failing-to-capture-the-entire-display/
    /*
    __block SCWindow* selfWindow = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent * _Nullable content, NSError * _Nullable error) {
        
        pid_t myPid = getpid();
        NSUInteger windowCnt = content.windows.count;
        
        for (NSUInteger i = 0; i< windowCnt; i++) {
            if ([self getPidFromWindowId:content.windows[i].windowID] == myPid) {
                selfWindow = content.windows[i];
                break;
            }
        }
        dispatch_semaphore_signal(semaphore);
    }];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
    NSLog(@"[ScreenRecorderImpl::start] selfWindow status : %d\n", selfWindow != nil ? 1 : 0);

    NSArray<SCWindow*>* excluding = (selfWindow != nil) ? @[ selfWindow ] : @[];
    NSArray<SCRunningApplication*>* excludingApp = @[];
    
    _recordFilter = [[SCContentFilter alloc] initWithDisplay:display excludingApplications:excludingApp exceptingWindows:excluding];
     */
    
    _recordFilter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
    if (_recordFilter == nil) return;
    
    // 녹화 설정 (해상도, 프레임 등)
    _recordConfig = [[SCStreamConfiguration alloc] init];
    _recordConfig.width = width;
    _recordConfig.height = height;
    _recordConfig.queueDepth = 3;
    
    if (recordFormat == OSXRDP_RECORDFORMAT_NV12) {
        _recordConfig.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    }
    else {
        _recordConfig.pixelFormat = kCVPixelFormatType_32BGRA;
    }
    
    _recordConfig.showsCursor = NO;
    
    // todo : 이것이 없는 구형 os 는 어떻게 확인하지..?
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

- (pid_t)getPidFromWindowId:(CGWindowID)windowId {
    CFArrayRef windowInfoArray = CGWindowListCopyWindowInfo(
        kCGWindowListOptionIncludingWindow,
        windowId
    );
    
    if (windowInfoArray == NULL) {
        return -1;
    }

    pid_t pid = -1;

    NSArray* info = CFBridgingRelease(windowInfoArray);
    for (NSDictionary* w in info) {
        NSNumber* winNum = w[(id)kCGWindowNumber];
        if (winNum && winNum.unsignedIntValue == windowId) {
            NSNumber* ownerPID = w[(id)kCGWindowOwnerPID];
            if (ownerPID) {
                pid = (pid_t)ownerPID.intValue;
            }
            break;
        }
    }

    return pid;
}

@end
