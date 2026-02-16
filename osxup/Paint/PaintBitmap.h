#ifndef PaintBitmap_h
#define PaintBitmap_h

#include "PaintBase.h"

class PaintBitmap : public PaintBase {
public:
    void Initialize(const struct mod* mod) override;
    void Release() override;
    void DoPaint(const struct mod* mod, screenrecord_frame_t* frameInfo, char* imgData, size_t imgDataSize, int frame_id) override;
};

#endif /* PaintBitmap_h */
