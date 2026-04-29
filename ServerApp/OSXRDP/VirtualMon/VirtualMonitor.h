
#ifndef VirtualMonitor_h
#define VirtualMonitor_h

#include "CGVirtualDisplayPrivate.h"
#include <pthread.h>

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
    
    bool IsRetina() {
        return _retina;
    }
    
    static void WakeupDisplay();
    
private:
    CGVirtualDisplay* _virtualDisplay;
    int _width;
    int _height;
    
    bool _retina;
    bool _init;
    
    uint32_t* _disabledDisplayIds;
    int _disabledDisplayIdsCnt;
    
    pthread_t _watchThread;
    pthread_mutex_t _watchLock;
    pthread_cond_t _watchWake;
    bool _watchRunning;
    bool _watchThreadCreated;
    
    int SetResolution();
    bool IsRightResolution();
    
    void WatchThreadPorcInternal();
    
    static void* WatchThreadProc(void* args);
};

#endif /* VirtualMonitor_h */
