#ifndef PaintManager_h
#define PaintManager_h

#include "PaintBase.h"
#include "osxrdp/screenrecordshm.h"
#include "xshm.h"

struct mod;

class PaintManager {

public:
    PaintManager();
    ~PaintManager();

    int Initialize(const struct mod* mod, int recordFormat, int sessionId, bool isLockScreen);
    void Release();
    bool TryReleaseForReconnect();

    void Paint();
    void PaintEnd(int ackFrameId);

    // Ask the producer to repaint the whole screen
    void RequestFullRepaint();

    // thread safe 하지 않지만, 동일 스레드에서 호출하므로 안전
    void PreparePaint(int displayIdx) {
        if (displayIdx >= 16) return;
        _needPaintDisplay[displayIdx] = 1;
    }

    static int CheckRecordFormat(const struct mod* mod);

private:
    static const int IN_FLIGHT_SLOT_COUNT = FRAME_SLOTS * 16;

    struct InFlightFrame {
        unsigned int frameId;
        int displayIdx;
        unsigned int shmReadPos;
        bool inUse;
    };

    bool _inited;
    PaintBase* _paint;

    xshm_t* _recordShm[16];
    int _recordShmCnt;

    xshm_t* _cursorShm;
    const struct mod* _mod;
    volatile bool _inPainting;
    volatile bool _releasePending;
    unsigned int _nextFrameGeneration;

    InFlightFrame _inFlightFrames[IN_FLIGHT_SLOT_COUNT];
    int _inFlightSlotQueue[IN_FLIGHT_SLOT_COUNT];
    int _freeInFlightSlots[IN_FLIGHT_SLOT_COUNT];
    int _freeInFlightCount;
    int _inFlightCountByDisplay[16];
    int _inFlightHead;
    int _inFlightCount;
    int _needPaintDisplay[16];

    bool GetPaintData(screenrecord_frame_t** outFrameInfo, char** outImgData, size_t* outImgDataSize, int* outWidth, int* outHeight, unsigned int* frame_id, int displayIdx);
    // Try to re-expose the last committed frame of an idle ring as a full
    // repaint (self-contained formats only). Never sets consumer_request_full;
    // clears it only when the rollback fully succeeds. Returns true on success.
    bool TryResubmitLastFrame(int displayIdx);
    bool PushInFlight(int displayIdx, unsigned int shmReadPos, unsigned int* outFrameId);
    int PopAckedInFlight(int ackFrameId, unsigned int* outMaxReadPosByDisplay, bool* outHasReadPosByDisplay);
    void ResetInFlight();
    void ReleaseResources();

    void PaintMouseCursor();
};

#endif
