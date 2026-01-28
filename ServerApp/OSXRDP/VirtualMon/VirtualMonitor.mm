#include "VirtualMonitor.h"

VirtualMonitor::VirtualMonitor() :
    _virtualDisplay(nil),
    _width(0),
    _height(0),
    _disabledDisplayIds(NULL),
    _disabledDisplayIdsCnt(0)
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
    desc.queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    desc.name = @"OSXRDP Virtual Display";
    desc.maxPixelsWide = width;
    desc.maxPixelsHigh = height;
    desc.sizeInMillimeters = CGSize(width, height);
    desc.productID = 0x5969;
    desc.vendorID = 0x1207;
    desc.serialNum = 0x0007;
    
    CGVirtualDisplayMode* mode = [[CGVirtualDisplayMode alloc] initWithWidth:width height:height refreshRate:60];
    if (mode == nil) return -1;
    
    //CGVirtualDisplayMode* retinaMode = [[CGVirtualDisplayMode alloc] initWithWidth:width * 2 height:height * 2 refreshRate:60];
    //if (mode == nil) return -1;
    
    CGVirtualDisplaySettings* settings = [[CGVirtualDisplaySettings alloc] init];
    if (settings == nil) return -1;
    settings.hiDPI = 1;
    
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
        mode
    ];
    
    _width = width;
    _height = height;
    
    _virtualDisplay = [[CGVirtualDisplay alloc] initWithDescriptor:desc];
    if (_virtualDisplay == nil) return -1;

    [_virtualDisplay applySettings:settings];
    
    // todo: 구형 os 에서 너무 빠르게 다음 작업을 수행하면 실패하는 경우가 있는것 같음... 지저분하지만 일단 이렇게..
    sleep(1);
    
    return _virtualDisplay.displayID;
}

void VirtualMonitor::Destroy() {
    // nil 로 설정하면 알아서 뽀개짐
    _virtualDisplay = nil;
    _width = 0;
    _height = 0;
    
    // 비활성화한 디스플레이 롤백
    RestoreOtherMonitors();
}

void VirtualMonitor::RestoreOtherMonitors() {
    if (_disabledDisplayIdsCnt == 0 || _disabledDisplayIds == NULL) {
        return;
    }
    
    CGDisplayConfigRef cfg = NULL;
    CGBeginDisplayConfiguration(&cfg);
    
    if (cfg == NULL) {
        return;
    }
    
    // 다시 켜기
    for (uint32_t i = 0; i < _disabledDisplayIdsCnt; i++) {
        CGSConfigureDisplayEnabled(cfg, _disabledDisplayIds[i], true);
    }
    
    free(_disabledDisplayIds);
    _disabledDisplayIds = NULL;
    _disabledDisplayIdsCnt = 0;
    
    // 설정 저장
    CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly);
}

bool VirtualMonitor::DisableOtherMonitors() {
    // 가상 디스플레이가 없으면 무시
    if (_virtualDisplay == nil) return false;
    
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
    
    CGDisplayConfigRef cfg = NULL;
    CGBeginDisplayConfiguration(&cfg);
    
    if (cfg == NULL) {
        free(displayIds);
        
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
    CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly);

    free(displayIds);
    
    // 가상 디스플레이의 해상도 설정
    SetResolution(_width, _height);
    
    return true;
}

void VirtualMonitor::SetResolution(int width, int height) {
    CGDisplayModeRef bestMode = NULL;
        
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(_virtualDisplay.displayID, NULL);
    if (modes == NULL) {
        return;
    }
    
    CFIndex cnt = CFArrayGetCount(modes);
    for (CFIndex i = 0; i < cnt; i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        
        size_t modeWidth = CGDisplayModeGetWidth(mode);
        size_t modeHeight = CGDisplayModeGetHeight(mode);
        
        if (modeWidth == width && modeHeight == height) {
            printf("found bestmode\n");
            bestMode = mode;
            break;
        }
    }
    
    if (bestMode == NULL) {
        printf("bestmode is null\n");
        
        CFRelease(modes);
        
        return;
    }
    
    CGError err = CGDisplaySetDisplayMode(_virtualDisplay.displayID, bestMode, NULL);
    if (err != kCGErrorSuccess) {
        printf("Configure Resolution Failed. %d \n", err);
    }
    
    CFRelease(modes);
}
