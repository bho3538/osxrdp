#ifndef PaintBase_h
#define PaintBase_h

#include "osxrdp/packet.h"
#include "osxrdp/screenrecordshm.h"

struct mod;

class PaintBase {
public:
    PaintBase() {};
    virtual ~PaintBase() {}
    
    virtual void Initialize(const struct mod* mod) = 0;
    virtual void Release() = 0;
    virtual void DoPaint(const struct mod* mod, screenrecord_frame_t* frameInfo, char* imgData, size_t imgDataSize, int frame_id) = 0;
};

#endif
