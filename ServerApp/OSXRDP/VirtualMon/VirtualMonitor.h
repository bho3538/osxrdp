
#ifndef VirtualMonitor_h
#define VirtualMonitor_h

#include "CGVirtualDisplayPrivate.h"
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <pthread.h>

struct VIRTUALMONITOR_INFO {
    int left;
    int top;
    int width;
    int height;
    // Descriptor-level pixel caps fixed at creation; an in-place resize beyond
    // these can never succeed and requires destroying/recreating the display
    int max_width;
    int max_height;
    int is_retina;
    int is_primary;
    // Set once the target resolution has been reached at least once.
    // After that, an external mode change (user picking a scaling option in
    // System Settings) is adopted instead of being reverted by the watchdog.
    int resolution_established;
    // Last observed mode point size, used to detect external mode changes
    // once the target resolution has been established.
    int last_mode_width;
    int last_mode_height;
    CGVirtualDisplay* virtualDisplay;
};

// Invoked from the watch thread (while its lock is held) when a
// user-selected display mode is adopted. The callback must only set a flag.
typedef void (*on_display_mode_adopted)(void* userData);

class VirtualMonitor {
public:
    VirtualMonitor();
    ~VirtualMonitor();

    // 가상 모니터를 생성
    bool Create(int width, int height, int left, int top, int index, bool isPrimary = false);

    // Change the resolution/layout of an existing virtual monitor without destroying it (dynamic resolution change)
    bool Resize(int index, int width, int height, int left, int top, bool isPrimary);

    // 모든 가상 모니터를 파괴
    void Destroy();

    // 가상 모니터를 제외한 나머지 모니터를 비활성화
    // 가상 모니터를 파괴 시 원래대로 돌아옴
    bool DisableOtherMonitors();

    // 비활성화 하였던 나머지 모니터들을 다시 활성화
    void RestoreOtherMonitors();

    void StartMonitor();

    // Register a callback invoked when the watchdog adopts a display mode
    // that the user selected externally (e.g. in System Settings)
    void SetModeAdoptedCallback(on_display_mode_adopted cb, void* userData);

    bool IsRetina(int index) {
        if (index >= _virtualDisplayInfoCnt) return false;
        return _virtualDisplayInfo[index].is_retina == 0 ? false : true;
    }

    int GetDisplayId(int index) {
        if (index >= _virtualDisplayInfoCnt) return -1;
        return (int)_virtualDisplayInfo[index].virtualDisplay.displayID;
    }

    void HoldDisplaySleepAssertion();
    void ReleaseDisplaySleepAssertion();

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
    IOPMAssertionID _displaySleepAssertion;

    on_display_mode_adopted _modeAdoptedCallback;
    void* _modeAdoptedCallbackUserData;

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
