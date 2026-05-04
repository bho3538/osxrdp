
#ifndef PaintH264_h
#define PaintH264_h

#include "PaintBase.h"
#include "xstream.h"

class PaintH264 : public PaintBase {
public:
    void Initialize(const struct mod* mod) override;
    void Release() override;
    void DoPaint(const struct mod* mod, screenrecord_frame_t* frameInfo, char* imgData, size_t imgDataSize, int frame_id, int displayId) override;
    
private:
    xstream_t* _drawCmd = NULL;
};


#endif /* PaintH264_h */
