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
    bool _inited;
    PaintBase* _paint;
    xshm_t* _recordShm;
    xshm_t* _cursorShm;
    const struct mod* _mod;
    volatile bool _inPainting;
    volatile bool _releasePending;
    unsigned int _nextFrameId;

    unsigned int _inFlightFrameIds[FRAME_SLOTS];
    unsigned int _inFlightReadPos[FRAME_SLOTS];
    int _inFlightHead;
    int _inFlightCount;
    
    bool GetPaintData(screenrecord_frame_t** outFrameInfo, char** outImgData, size_t* outImgDataSize, unsigned int* frame_id);
    bool PushInFlight(unsigned int frameId, unsigned int shmReadPos);
    int PopAckedInFlight(int ackFrameId, unsigned int* outMaxReadPos);
    void ResetInFlight();
    void ReleaseResources();
    
    void PaintMouseCursor();
};

#endif
