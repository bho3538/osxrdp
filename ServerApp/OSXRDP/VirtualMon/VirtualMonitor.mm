#include "VirtualMonitor.h"
#include "DisplayUtils.h"

#include <IOKit/pwr_mgt/IOPMLib.h>
#include <unistd.h>

VirtualMonitor::VirtualMonitor() :
    _virtualDisplay(nil),
    _width(0),
    _height(0),
    _disabledDisplayIds(NULL),
    _disabledDisplayIdsCnt(0),
    _retina(false),
    _init(false),
    _watchRunning(false),
    _watchThreadCreated(false)
{
    pthread_mutex_init(&_watchLock, 0);
    pthread_cond_init(&_watchWake, 0);
}

VirtualMonitor::~VirtualMonitor() {
    Destroy();
    
    pthread_cond_destroy(&_watchWake);
    pthread_mutex_destroy(&_watchLock);
}

int VirtualMonitor::Create(int width, int height) {
    // 이미 가상 디스플레이가 있는 경우 뽀개고 다시 만들기
    if (_virtualDisplay != nil) {
        Destroy();
    }
    
    // 가상 디스플레이를 생성
    CGVirtualDisplayDescriptor* desc = [[CGVirtualDisplayDescriptor alloc] init];
    if (desc == nil) return -1;
    
    // 가상 디스플레이의 기본 속성
    desc.queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
    desc.name = @"OSXRDP Virtual Display";
    desc.maxPixelsWide = width;
    desc.maxPixelsHigh = height;
    desc.sizeInMillimeters = CGSizeMake(width * 25.4 / 96,
                                        height * 25.4 / 96);
    
    desc.productID = 0x5969;
    desc.vendorID = 0x1207;
    desc.serialNum = 0x0007;
    
    CGVirtualDisplayMode* mode = [[CGVirtualDisplayMode alloc] initWithWidth:width height:height refreshRate:60];
    if (mode == nil) return -1;
    
    CGVirtualDisplayMode* retinaMode = [[CGVirtualDisplayMode alloc] initWithWidth:width / 2 height:height / 2 refreshRate:60];
    if (retinaMode == nil) return -1;
    
    CGVirtualDisplaySettings* settings = [[CGVirtualDisplaySettings alloc] init];
    if (settings == nil) return -1;
    
    // 특정 해상도 이상일 경우 hidpi 모드
    if (width > 2300 && height > 1500) {
        settings.hiDPI = 1;
        _retina = true;
    }
    else {
        settings.hiDPI = 0;
        _retina = false;
    }
    
    // 이와 같이 구성을 채우지 않으면 macOS 가 이를 모니터가 아닌 다른 무언가로 인식하여 대화상자를 띄우는것 같음 (airplay 수신기?)
    // 따라서 기본 구성을 진짜 모니터처럼 넣고 xrdp 해상도를 마지막에 넣는다.
    settings.modes = @[
        [[CGVirtualDisplayMode alloc] initWithWidth:3840 height:2160 refreshRate:60],
        [[CGVirtualDisplayMode alloc] initWithWidth:2560 height:1440 refreshRate:60],
        [[CGVirtualDisplayMode alloc] initWithWidth:1920 height:1080 refreshRate:60],
        [[CGVirtualDisplayMode alloc] initWithWidth:1600 height:900 refreshRate:60],
        [[CGVirtualDisplayMode alloc] initWithWidth:1366 height:768 refreshRate:60],
        [[CGVirtualDisplayMode alloc] initWithWidth:1280 height:720 refreshRate:60],
        [[CGVirtualDisplayMode alloc] initWithWidth:2560 height:1600 refreshRate:60],
        [[CGVirtualDisplayMode alloc] initWithWidth:1920 height:1200 refreshRate:60],
        [[CGVirtualDisplayMode alloc] initWithWidth:1680 height:1050 refreshRate:60],
        [[CGVirtualDisplayMode alloc] initWithWidth:1440 height:900 refreshRate:60],
        [[CGVirtualDisplayMode alloc] initWithWidth:1280 height:800 refreshRate:60],
        mode,
        retinaMode
    ];
    
    _width = width;
    _height = height;
    
    _virtualDisplay = [[CGVirtualDisplay alloc] initWithDescriptor:desc];
    if (_virtualDisplay == nil) return -1;
    
    // 가상 디스플레이 속성 적용
    [_virtualDisplay applySettings:settings];
    
    WakeupDisplay();
    
    // watch thread 생성
    _watchRunning = true;
    if (pthread_create(&_watchThread , NULL, WatchThreadProc, this) == 0) {
        _watchThreadCreated = true;
    }
    else {
        _watchRunning = false;
    }
    
    return _virtualDisplay.displayID;
}

void VirtualMonitor::Destroy() {
    // 가상 모미터 watch 스레드 정지
    _watchRunning = false;
    if (_watchThreadCreated) {
        pthread_cond_signal(&_watchWake);
        pthread_join(_watchThread, NULL); // 완전히 정지할때까지 대기
        _watchThreadCreated = false;
    }
    
    // 비활성화한 디스플레이 롤백 (반드시 먼저 해야함, 그렇지 않는 경우 위 설명처럼 windowserver 가 크래시할 수 있음)
    RestoreOtherMonitors();

    // nil 로 설정하면 알아서 뽀개짐 (즉시 뽀개지는건 아님)
    _virtualDisplay = nil;
    _init = false;
}

void VirtualMonitor::RestoreOtherMonitors() {
    if (_disabledDisplayIdsCnt == 0 || _disabledDisplayIds == NULL) {
        return;
    }
    
    DisplayUtils::ApplyDisplayEnabled(_disabledDisplayIds, _disabledDisplayIdsCnt, true);
    
    free(_disabledDisplayIds);
    
    _disabledDisplayIds = NULL;
    _disabledDisplayIdsCnt = 0;
}

void VirtualMonitor::WakeupDisplay() {
    IOPMAssertionID assertionID = kIOPMNullAssertionID;
    IOPMAssertionDeclareUserActivity(CFSTR("OSXRDP: wake display"), kIOPMUserActiveLocal, &assertionID);
    if (assertionID != kIOPMNullAssertionID) {
        IOPMAssertionRelease(assertionID);
        assertionID = kIOPMNullAssertionID;
    }

    // hack : 바로 안꺠어나는 경우가 있음
    //usleep(150 * 1000);
}

// todo: DisplayUtils::ApplyDisplayEnabled 에 중복 로직이 있음
bool VirtualMonitor::DisableOtherMonitors() {
    NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors begin virtualDisplay=%p disabledCnt=%d]", _virtualDisplay, _disabledDisplayIdsCnt);
    
    // 가상 디스플레이가 없으면 무시
    if (_virtualDisplay == nil) {
        NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors failed reason=noVirtualDisplay]");
        return false;
    }
    
    // 디스플레이 갯수를 조회
    uint32_t displayCnt = 0;
    CGError displayListErr = CGGetOnlineDisplayList(0, NULL, &displayCnt);
    NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors onlineCnt=%u err=%d virtualId=%u]", displayCnt, displayListErr, _virtualDisplay.displayID);
    
    if (displayListErr != kCGErrorSuccess || displayCnt == 0) {
        NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors failed reason=noDisplay err=%d cnt=%u]", displayListErr, displayCnt);
        return false;
    }
    
    // 디스플레이 id 들을 조회
    CGDirectDisplayID* displayIds = (CGDirectDisplayID*)malloc(sizeof(CGDirectDisplayID) * displayCnt);
    if (displayIds == NULL) {
        NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors failed reason=mallocDisplayIds cnt=%u]", displayCnt);
        return false;
    }
    
    displayListErr = CGGetOnlineDisplayList(displayCnt, displayIds, NULL);
    if (displayListErr != kCGErrorSuccess) {
        NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors failed reason=getDisplayList err=%d cnt=%u]", displayListErr, displayCnt);
        free(displayIds);
        
        return false;
    }
    
    uint32_t* newDisabledDisplayIds = (uint32_t*)realloc(_disabledDisplayIds, sizeof(uint32_t) * (_disabledDisplayIdsCnt + displayCnt));
    if (newDisabledDisplayIds == NULL) {
        NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors failed reason=realloc oldCnt=%d addCnt=%u]", _disabledDisplayIdsCnt, displayCnt);
        free(displayIds);
        return false;
    }
    
    _disabledDisplayIds = newDisabledDisplayIds;
    
    CGDisplayConfigRef cfg = NULL;
    CGError beginErr = CGBeginDisplayConfiguration(&cfg);
    if (beginErr != kCGErrorSuccess || cfg == NULL) {
        NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors failed reason=beginConfiguration err=%d cfg=%p]", beginErr, cfg);
        free(displayIds);
        
        return false;
    }
    
    int newDisabledDisplayIdsCnt = _disabledDisplayIdsCnt;
    
    for (uint32_t i = 0; i < displayCnt; i++) {
        NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors check id=%u index=%u]", displayIds[i], i);
        
        if (displayIds[i] == _virtualDisplay.displayID) {
            NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors skip virtual id=%u]", displayIds[i]);
            continue;
        }
        
        // 물리 디스플레이를 끄도록 구성
        CGError configureErr = CGSConfigureDisplayEnabled(cfg, displayIds[i], false);
        NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors configure id=%u enabled=0 err=%d]", displayIds[i], configureErr);
        
        bool exists = false;
        for (int j = 0; j < _disabledDisplayIdsCnt; j++) {
            if (_disabledDisplayIds[j] == displayIds[i]) {
                exists = true;
                break;
            }
        }
        
        if (exists == false) {
            // 나중에 복원할 수 있도록 id 를 저장
            _disabledDisplayIds[newDisabledDisplayIdsCnt] = displayIds[i];
            newDisabledDisplayIdsCnt++;
            NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors add disabled id=%u newCnt=%d]", displayIds[i], newDisabledDisplayIdsCnt);
        }
        else {
            NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors skip duplicate id=%u]", displayIds[i]);
        }
    }
    
    // 설정 저장
    CGError completeErr = CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly);
    if (completeErr != kCGErrorSuccess) {
        NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors failed reason=complete err=%d oldCnt=%d newCnt=%d]", completeErr, _disabledDisplayIdsCnt, newDisabledDisplayIdsCnt);
        free(displayIds);
        return false;
    }
    
    _disabledDisplayIdsCnt = newDisabledDisplayIdsCnt;
    NSLog(@"[VirtualMonDebugMsg : DisableOtherMonitors success disabledCnt=%d]", _disabledDisplayIdsCnt);
    
    free(displayIds);
    
    return true;
}

int VirtualMonitor::SetResolution() {
    CGDisplayModeRef bestMode = NULL;
    
    // Retina 해상도 까지 조회하기 위한 옵션
    CFStringRef keys[1] = { kCGDisplayShowDuplicateLowResolutionModes };
    CFTypeRef values[1] = { kCFBooleanTrue };
        
    CFDictionaryRef options = CFDictionaryCreate(
        kCFAllocatorDefault,
        (const void **)keys,
        (const void **)values,
        1,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
        
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(_virtualDisplay.displayID, options);
    if (modes == NULL) {
        NSLog(@"[VirtualMonitor::SetResolution] CGDisplayCopyAllDisplayModes null\n");
        CFRelease(options);
        
        return 1;
    }
    
    if (_retina) {
        CFIndex cnt = CFArrayGetCount(modes);
        // Retina (HiDPI) 가 먹힌 해상도를 먼저 찾기
        for (CFIndex i = 0; i < cnt; i++) {
            CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
            
            size_t modeWidth = CGDisplayModeGetWidth(mode);
            size_t modeHeight = CGDisplayModeGetHeight(mode);
            
            if (modeWidth == (_width / 2) && modeHeight == (_height / 2)) {
                NSLog(@"found retina bestmode\n");
                bestMode = mode;
                break;
            }
        }
        
        // Retina 해상도를 찾지 못한 경우 일반 해상도를 찾기
        if (bestMode == NULL) {
            CFIndex cnt = CFArrayGetCount(modes);
            for (CFIndex i = 0; i < cnt; i++) {
                CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
                
                size_t modeWidth = CGDisplayModeGetWidth(mode);
                size_t modeHeight = CGDisplayModeGetHeight(mode);
                
                if (modeWidth == _width && modeHeight == _height) {
                    NSLog(@"found bestmode\n");
                    bestMode = mode;
                    break;
                }
            }
        }
    }
    else {
        CFIndex cnt = CFArrayGetCount(modes);
        for (CFIndex i = 0; i < cnt; i++) {
            CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
            
            size_t modeWidth = CGDisplayModeGetWidth(mode);
            size_t modeHeight = CGDisplayModeGetHeight(mode);
            
            if (modeWidth == _width && modeHeight == _height) {
                NSLog(@"found bestmode\n");
                bestMode = mode;
                break;
            }
        }
    }
    
    if (bestMode == NULL) {
        NSLog(@"bestmode is null\n");
        
        CFRelease(modes);
        CFRelease(options);
        
        return 1;
    }
    
    CGError err = CGDisplaySetDisplayMode(_virtualDisplay.displayID, bestMode, NULL);
    if (err != kCGErrorSuccess) {
        printf("Configure Resolution Failed. %d \n", err);
    }
    
    CFRelease(modes);
    CFRelease(options);
    
    return err == kCGErrorSuccess ? 0 : 1;
}

bool VirtualMonitor::IsRightResolution() {
    if (_virtualDisplay == nil) {
        return false;
    }
    
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(_virtualDisplay.displayID);
    if (mode == NULL) {
        return false;
    }
    
    size_t modeWidth = CGDisplayModeGetWidth(mode);
    size_t modeHeight = CGDisplayModeGetHeight(mode);
    size_t pixelWidth = CGDisplayModeGetPixelWidth(mode);
    size_t pixelHeight = CGDisplayModeGetPixelHeight(mode);
    
    bool result = false;
    if (_retina) {
        result = (modeWidth == (_width / 2) && modeHeight == (_height / 2) &&
                  pixelWidth == _width && pixelHeight == _height);
    }
    else {
        result = (modeWidth == _width && modeHeight == _height &&
                  pixelWidth == _width && pixelHeight == _height);
    }
    
    CFRelease(mode);
    
    return result;
}

void* VirtualMonitor::WatchThreadProc(void* args) {
    
    if (args == NULL) return NULL;
    VirtualMonitor* _this = (VirtualMonitor*)args;
    
    pthread_mutex_lock(&_this->_watchLock);
    
    for(;;) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_sec += 2;
        
        pthread_cond_timedwait(&_this->_watchWake, &_this->_watchLock, &ts);
        
        if (_this->_watchRunning == false) break;
        
        _this->WatchThreadPorcInternal();
    }
    
    pthread_mutex_unlock(&_this->_watchLock);
    
    return NULL;
}

void VirtualMonitor::WatchThreadPorcInternal() {
    // 아직 가상 모니터가 완전히 활성화 되어있는지 확인하지 못한 상황
    if (_init == false) {
        // 가상 모니터가 완전히 사용 가능한지 확인
        if (DisplayUtils::IsDisplayOnline(_virtualDisplay.displayID) == false) {
            NSLog(@"[VirtualMonitor::WatchThreadProc] virtual display does not online yet");
            return;
        }
        
        NSLog(@"[VirtualMonitor::WatchThreadProc] virtual display has been online now");
        _init = true;
    }
    
    // 가상 모니터를 제외한 다른 모니터가 온라인인지 확인
    if (DisplayUtils::HasOtherOnlineDisplay(_virtualDisplay.displayID) == true) {
        NSLog(@"[VirtualMonitor::WatchThreadProc] other display is online. try disable it");

        // 다른 모니터 disable (혹은 신규 추가 모니터 비활성화)
        DisableOtherMonitors();
    }
    
    // 해상도 정보 확인 (가상 모니터)
    if (IsRightResolution() == false) {
        // 해상도가 틀어진 경우 (혹은 아직 설정되지 않은 경우) --> 해상도 설정
        NSLog(@"[VirtualMonitor::WatchThreadProc] virtual display has invalid resolution. try change it");
        SetResolution();
    }
}
