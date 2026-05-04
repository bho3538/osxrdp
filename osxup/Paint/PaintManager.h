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
    
    bool GetPaintData(screenrecord_frame_t** outFrameInfo, char** outImgData, size_t* outImgDataSize, unsigned int* frame_id, int displayIdx);
    bool PushInFlight(int displayIdx, unsigned int shmReadPos, unsigned int* outFrameId);
    int PopAckedInFlight(int ackFrameId, unsigned int* outMaxReadPosByDisplay, bool* outHasReadPosByDisplay);
    void ResetInFlight();
    void ReleaseResources();
    
    void PaintMouseCursor();
};

#endif
