#include "VirtualMonitor.h"

VirtualMonitor::VirtualMonitor() :
    _virtualDisplay(nil)
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
    desc.productID = 0x4321;
    desc.vendorID = 0x1234;
    desc.serialNum = 0x0001;
    
    CGVirtualDisplayMode* mode = [[CGVirtualDisplayMode alloc] initWithWidth:width height:height refreshRate:60];
    if (mode == nil) return -1;
    
    CGVirtualDisplaySettings* settings = [[CGVirtualDisplaySettings alloc] init];
    if (settings == nil) return -1;
    settings.hiDPI = 0;
    settings.modes = @[mode];
    
    _virtualDisplay = [[CGVirtualDisplay alloc] initWithDescriptor:desc];
    if (_virtualDisplay == nil) return -1;

    [_virtualDisplay applySettings:settings];
    
    return _virtualDisplay.displayID;
}

void VirtualMonitor::Destroy() {
    // nil 로 설정하면 알아서 뽀개짐
    _virtualDisplay = nil;
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
    
    CGDisplayConfigRef cfg = NULL;
    CGBeginDisplayConfiguration(&cfg);
    
    if (cfg == NULL) {
        free(displayIds);
        
        return false;
    }
    
    for (uint32_t i = 0; i < displayCnt; i++) {
        if (displayIds[i] == _virtualDisplay.displayID) {
            continue;;
        }
        
        // 가상 디스플레이를 미러링하도록 구성
        CGConfigureDisplayMirrorOfDisplay(cfg, displayIds[i], _virtualDisplay.displayID);
    }
    
    // 설정 저장
    CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly);
    
    free(displayIds);
    
    return true;
}
