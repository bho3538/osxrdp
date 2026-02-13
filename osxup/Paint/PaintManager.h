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
    
    void Paint();
    
    static int CheckRecordFormat(const struct mod* mod);
    
private:
    bool _inited;
    PaintBase* _paint;
    xshm_t* _recordShm;
    xshm_t* _cursorShm;
    const struct mod* _mod;
    
    bool GetPaintData(screenrecord_frame_t** outFrameInfo, char** outImgData, size_t* outImgDataSize, unsigned int* frame_id);
    
    void PaintMouseCursor();
};

#endif

