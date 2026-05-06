
#ifndef VirtualMonitor_h
#define VirtualMonitor_h

#include "CGVirtualDisplayPrivate.h"
#include <pthread.h>

struct VIRTUALMONITOR_INFO {
    int left;
    int top;
    int width;
    int height;
    int is_retina;
    int is_primary;
    CGVirtualDisplay* virtualDisplay;
};

class VirtualMonitor {
public:
    VirtualMonitor();
    ~VirtualMonitor();
    
    // 가상 모니터를 생성
    bool Create(int width, int height, int left, int top, int index, bool isPrimary = false);
    
    // 모든 가상 모니터를 파괴
    void Destroy();
    
    // 가상 모니터를 제외한 나머지 모니터를 비활성화
    // 가상 모니터를 파괴 시 원래대로 돌아옴
    bool DisableOtherMonitors();
    
    // 비활성화 하였던 나머지 모니터들을 다시 활성화
    void RestoreOtherMonitors();
    
    void StartMonitor();
    
    bool IsRetina(int index) {
        if (index >= _virtualDisplayInfoCnt) return false;
        return _virtualDisplayInfo[index].is_retina == 0 ? false : true;
    }
    
    int GetDisplayId(int index) {
        if (index >= _virtualDisplayInfoCnt) return -1;
        return (int)_virtualDisplayInfo[index].virtualDisplay.displayID;
    }
    
    static void WakeupDisplay();
    
private:

    struct VIRTUALMONITOR_INFO _virtualDisplayInfo[16];
    int _virtualDisplayInfoCnt;

    bool _init;
    
    uint32_t* _disabledDisplayIds;
    int _disabledDisplayIdsCnt;
    
    pthread_t _watchThread;
    pthread_mutex_t _watchLock;
    pthread_cond_t _watchWake;
    bool _watchRunning;

    bool IsVirtualDisplay(CGDirectDisplayID displayId);
    bool IsAllVirtualDisplayOnline();
    int GetPrimaryDisplayIndex();
    bool IsRightPrimaryDisplay();
    bool IsRightDisplayLayout();

    int SetResolution(int index);
    bool IsRightResolution(int index);
    int SetPrimaryDisplay();
    int ApplyDisplayLayout();
    
    void WatchThreadPorcInternal();
    
    static void* WatchThreadProc(void* args);
};

#endif /* VirtualMonitor_h */
