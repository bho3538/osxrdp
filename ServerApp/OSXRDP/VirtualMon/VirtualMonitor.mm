#include "VirtualMonitor.h"
#include "DisplayReconfigWatcher.h"
#include "DisplayUtils.h"

#include <IOKit/pwr_mgt/IOPMLib.h>
#include <unistd.h>

static int kVirtualDetachTimeoutMs = 3000;
static int kReconfigQuietMs = 200;
static int kRestoreVerifyTimeoutMs = 2000;

VirtualMonitor::VirtualMonitor() :
    _virtualDisplay(nil),
    _width(0),
    _height(0),
    _disabledDisplayIds(NULL),
    _disabledDisplayIdsCnt(0),
    _retina(false)
{}

VirtualMonitor::~VirtualMonitor() {
    Destroy();
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
    desc.sizeInMillimeters = CGSize(width, height);
    desc.productID = 0x5969;
    desc.vendorID = 0x1207;
    desc.serialNum = 0x0007;
    
    CGVirtualDisplayMode* mode = [[CGVirtualDisplayMode alloc] initWithWidth:width height:height refreshRate:60];
    if (mode == nil) return -1;
    
    CGVirtualDisplayMode* retinaMode = [[CGVirtualDisplayMode alloc] initWithWidth:width / 2 height:height / 2 refreshRate:60];
    if (retinaMode == nil) return -1;
    
    CGVirtualDisplaySettings* settings = [[CGVirtualDisplaySettings alloc] init];
    if (settings == nil) return -1;
    
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
    
    DisableOtherMonitors();
    
    [_virtualDisplay applySettings:settings];
    
    // 가상 디스플레이의 해상도 설정
    // 가상 디스플레이가 완전히 추가될때까지 모니터 해상도를 조회할 수 없음. 따라서 여러번 시도 후 그래도 적용실패시 가상모니터 사용을 안하도록 유도
    int applyResolution = 0;
    for (int i = 0; i < 5; i++) {
        if (SetResolution(_width, _height, _retina) == 0) {
            applyResolution = 1;
            break;
        }
        
        sleep(1);
    }
    
    if (applyResolution == 0) {
        return -1;
    }
    
    return _virtualDisplay.displayID;
}

void VirtualMonitor::Destroy() {
    CGDirectDisplayID virtualDisplayId = 0;
    DisplayReconfigWatcher watcher;
    uint64_t seqAtStart = 0;

    // 가상 디스플레이를 뽀개기 전 마지막 상태를 저장
    if (_virtualDisplay != nil) {
        virtualDisplayId = _virtualDisplay.displayID;
        if (watcher.Start()) {
            seqAtStart = watcher.Sequence();
        }
    }

    // nil 로 설정하면 알아서 뽀개짐 (즉시 뽀개지는건 아님)
    _virtualDisplay = nil;
    _width = 0;
    _height = 0;

    if (virtualDisplayId != 0) {
        // 특정 pc에서 virtual display 제거가 완벽히 끝나기 전에 복원을 시도하면 WindowServer 가 크래시하는 현상이 발생
        // 따라서 가상 디스플레이가 완전히 제거되고 crash 방지를 위해 WindowServer 이벤트가 잠잠해질때 까지 대기
        DisplayUtils::WaitDisplayOnlineState(virtualDisplayId, false, kVirtualDetachTimeoutMs);
        watcher.WaitForQuiet(seqAtStart, kReconfigQuietMs, kVirtualDetachTimeoutMs);
    }
    
    // 비활성화한 디스플레이 롤백
    RestoreOtherMonitors();
}

void VirtualMonitor::RestoreOtherMonitors() {
    if (_disabledDisplayIdsCnt == 0 || _disabledDisplayIds == NULL) {
        return;
    }
    
    // wakeup 없이 restore 시도
    bool restored = DisplayUtils::ApplyDisplayEnabled(_disabledDisplayIds, _disabledDisplayIdsCnt, true) &&
                    DisplayUtils::WaitAllDisplaysOnline(_disabledDisplayIds, _disabledDisplayIdsCnt, kRestoreVerifyTimeoutMs);

    if (restored == false) {
        // 필요할 때만 wakeup 후 재시도
        WakeupDisplay();
        restored = DisplayUtils::ApplyDisplayEnabled(_disabledDisplayIds, _disabledDisplayIdsCnt, true) &&
                   DisplayUtils::WaitAllDisplaysOnline(_disabledDisplayIds, _disabledDisplayIdsCnt, kRestoreVerifyTimeoutMs);
    }

    if (restored) {
        free(_disabledDisplayIds);
        _disabledDisplayIds = NULL;
        _disabledDisplayIdsCnt = 0;
    }
    else {
        NSLog(@"[VirtualMonitor::RestoreOtherMonitors] restore failed. keep disabled display list for retry.");
    }
}

void VirtualMonitor::WakeupDisplay() {
    IOPMAssertionID assertionID = kIOPMNullAssertionID;
    IOPMAssertionDeclareUserActivity(CFSTR("OSXRDP: wake display"), kIOPMUserActiveLocal, &assertionID);
    if (assertionID != kIOPMNullAssertionID) {
        IOPMAssertionRelease(assertionID);
        assertionID = kIOPMNullAssertionID;
    }

    usleep(150 * 1000);
}

// todo: DisplayUtils::ApplyDisplayEnabled 에 중복 로직이 있음
bool VirtualMonitor::DisableOtherMonitors() {
    // 가상 디스플레이가 없으면 무시
    if (_virtualDisplay == nil) return false;

    if (_disabledDisplayIds != NULL) {
        free(_disabledDisplayIds);
        _disabledDisplayIds = NULL;
        _disabledDisplayIdsCnt = 0;
    }
    
    // 디스플레이 갯수를 조회
    uint32_t displayCnt = 0;
    CGGetOnlineDisplayList(0, NULL, &displayCnt);
    
    if (displayCnt == 0) return false;
    
    // 디스플레이 id 들을 조회
    CGDirectDisplayID* displayIds = (CGDirectDisplayID*)malloc(sizeof(CGDirectDisplayID) * displayCnt);
    if (displayIds == NULL) {
        return false;
    }
    
    if (CGGetOnlineDisplayList(displayCnt, displayIds, NULL) != kCGErrorSuccess) {
        free(displayIds);
        
        return false;
    }
    
    _disabledDisplayIds = (uint32_t*)malloc(sizeof(uint32_t) * displayCnt);
    if (_disabledDisplayIds == NULL) {
        free(displayIds);
        
        return false;
    }

    _disabledDisplayIdsCnt = 0;
    
    CGDisplayConfigRef cfg = NULL;
    if (CGBeginDisplayConfiguration(&cfg) != kCGErrorSuccess || cfg == NULL) {
        free(displayIds);
        free(_disabledDisplayIds);
        _disabledDisplayIds = NULL;
        _disabledDisplayIdsCnt = 0;
        
        return false;
    }
    
    for (uint32_t i = 0; i < displayCnt; i++) {
        if (displayIds[i] == _virtualDisplay.displayID) {
            continue;
        }
        else {
            // 물리 디스플레이를 끄도록 구성
            CGSConfigureDisplayEnabled(cfg, displayIds[i], false);
            
            // 나중에 복원할 수 있도록 id 를 저장
            _disabledDisplayIds[_disabledDisplayIdsCnt] = displayIds[i];
            _disabledDisplayIdsCnt++;
        }
    }
    
    // 설정 저장
    CGError completeErr = CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly);
    if (completeErr != kCGErrorSuccess) {
        free(displayIds);
        free(_disabledDisplayIds);
        _disabledDisplayIds = NULL;
        _disabledDisplayIdsCnt = 0;
        return false;
    }

    free(displayIds);
    
    return true;
}

int VirtualMonitor::SetResolution(int width, int height, bool retinaMode) {
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
    
    if (retinaMode) {
        CFIndex cnt = CFArrayGetCount(modes);
        // Retina (HiDPI) 가 먹힌 해상도를 먼저 찾기
        for (CFIndex i = 0; i < cnt; i++) {
            CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
            
            size_t modeWidth = CGDisplayModeGetWidth(mode);
            size_t modeHeight = CGDisplayModeGetHeight(mode);
            //size_t pixelWidth = CGDisplayModeGetPixelWidth(mode);
            
            if (modeWidth == (width / 2) && modeHeight == (height / 2)) {
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
                
                if (modeWidth == width && modeHeight == height) {
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
            
            if (modeWidth == width && modeHeight == height) {
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
