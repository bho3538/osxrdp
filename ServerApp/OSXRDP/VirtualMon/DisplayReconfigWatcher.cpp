#include "DisplayReconfigWatcher.h"
#include <sys/time.h>
#include <unistd.h>

static const int WatcherPollIntervalMs = 30;

static uint64_t GetNowMs() {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return ((uint64_t)tv.tv_sec * 1000ULL) + ((uint64_t)tv.tv_usec / 1000ULL);
}

DisplayReconfigWatcher::DisplayReconfigWatcher() :
    _registered(false)
{
    atomic_init(&_seq, 0);
}

DisplayReconfigWatcher::~DisplayReconfigWatcher() {
    Stop();
}

bool DisplayReconfigWatcher::Start() {
    if (_registered) {
        return true;
    }

    // 디스플레이 관련 이벤트 콜백을 등록
    CGError err = CGDisplayRegisterReconfigurationCallback(&DisplayReconfigWatcher::Callback, this);
    _registered = (err == kCGErrorSuccess);
    return _registered;
}

void DisplayReconfigWatcher::Stop() {
    if (_registered) {
        CGDisplayRemoveReconfigurationCallback(&DisplayReconfigWatcher::Callback, this);
        _registered = false;
    }
}

uint64_t DisplayReconfigWatcher::Sequence() const {
    return (uint64_t)atomic_load_explicit(&_seq, memory_order_relaxed);
}

bool DisplayReconfigWatcher::WaitForQuiet(uint64_t seqAtStart, int quietMs, int timeoutMs) const {
    if (_registered == false) {
        return true;
    }

    uint64_t beginMs = GetNowMs();
    uint64_t quietSinceMs = beginMs;
    uint64_t lastSeq = seqAtStart;

    while (true) {
        uint64_t currentSeq = Sequence();
        uint64_t nowMs = GetNowMs();

        if (currentSeq != lastSeq) {
            lastSeq = currentSeq;
            quietSinceMs = nowMs;
        }
        else {
            int quietElapsed = (int)(nowMs - quietSinceMs);
            if (quietElapsed >= quietMs) {
                return true;
            }
        }

        int totalElapsed = (int)(nowMs - beginMs);
        if (totalElapsed >= timeoutMs) {
            return false;
        }

        usleep(WatcherPollIntervalMs * 1000);
    }
}

void DisplayReconfigWatcher::Callback(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void* userInfo) {
    (void)display;
    (void)flags;

    // 무언가 이벤트가 온 경우 + 1
    DisplayReconfigWatcher* self = (DisplayReconfigWatcher*)userInfo;
    if (self != NULL) {
        atomic_fetch_add_explicit(&self->_seq, 1, memory_order_relaxed);
    }
}
