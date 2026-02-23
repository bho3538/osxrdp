#ifndef DisplayReconfigWatcher_h
#define DisplayReconfigWatcher_h

#include <CoreGraphics/CoreGraphics.h>
#include <stdint.h>
#include <stdatomic.h>

class DisplayReconfigWatcher {
public:
    DisplayReconfigWatcher();
    ~DisplayReconfigWatcher();

    bool Start();
    void Stop();
    uint64_t Sequence() const;
    bool WaitForQuiet(uint64_t seqAtStart, int quietMs, int timeoutMs) const;

private:
    static void Callback(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void* userInfo);

private:
    atomic_uint_fast64_t _seq;
    bool _registered;
};

#endif /* DisplayReconfigWatcher_h */
