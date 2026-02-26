#ifndef DisplayUtils_h
#define DisplayUtils_h

#include <CoreGraphics/CoreGraphics.h>
#include <stdint.h>

class DisplayUtils {
public:
    // 디스플레이가 온라인 상태인지 확인
    static bool IsDisplayOnline(CGDirectDisplayID displayId);
    
    // 디스플레이가 특정 상태로 전환될때까지 대기 (온라인/오프라인)
    static bool WaitDisplayOnlineState(CGDirectDisplayID displayId, bool shouldBeOnline, int timeoutMs);
    
    // 디스플레이 on/off
    static bool ApplyDisplayEnabled(uint32_t* displayIds, int displayCnt, bool enabled);
    
    // 주어진 디스플레이가 온라인 혹은 오프라인 상태일때까지 대기
    static bool WaitAllDisplaysOnline(uint32_t* displayIds, int displayCnt, int timeoutMs, bool online);
};

#endif /* DisplayUtils_h */
