#ifndef PaintRFX_h
#define PaintRFX_h

#include "PaintBase.h"
#include "xstream.h"

class PaintRFX : public PaintBase {
public:
    void Initialize(const struct mod* mod) override;
    void Release() override;
    void DoPaint(const struct mod* mod, screenrecord_frame_t* frameInfo, char* imgData, size_t imgDataSize, int frame_id) override;
    
private:
    xstream_t* _drawCmd = NULL;
};

#endif /* PaintRFX_h */
