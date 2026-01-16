
#ifndef VirtualMonitor_h
#define VirtualMonitor_h

#include "CGVirtualDisplayPrivate.h"

class VirtualMonitor {
public:
    VirtualMonitor();
    ~VirtualMonitor();
    
    // 가상 모니터를 생성 (반환값 : 가상 모니터의 id)
    int Create(int width, int height);
    
    // 가상 모니터를 파괴
    void Destroy();
    
    // 가상 모니터를 제외한 나머지 모니터를 비활성화
    // 가상 모니터를 파괴 시 원래대로 돌아옴
    bool DisableOtherMonitors();
    
    // 비활성화 하였던 나머지 모니터들을 다시 활성화
    void RestoreOtherMonitors();
    
private:
    __strong CGVirtualDisplay* _virtualDisplay;
    int _width;
    int _height;
    
    uint32_t* _disabledDisplayIds;
    int _disabledDisplayIdsCnt;
    
    void SetResolution(CGDisplayConfigRef cfg, int width, int height);
};

#endif /* VirtualMonitor_h */
