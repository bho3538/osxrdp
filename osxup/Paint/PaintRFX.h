#ifndef PaintRFX_h
#define PaintRFX_h

#include "PaintBase.h"
#include "xstream.h"

class PaintRFX : public PaintBase {
public:
    void Initialize(const struct mod* mod) override;
    void Release() override;
    void DoPaint(const struct mod* mod, screenrecord_frame_t* frameInfo, char* imgData, size_t imgDataSize, int frame_id) override;

    // RFX slot 은 "이번 프레임에서 변화된 타일"만 담는 partial-frame 포맷이다.
    bool FrameIsSelfContained() const override { return false; }

private:
    struct TileRect {
        short left;
        short top;
        short width;
        short height;
    };

    xstream_t* _drawCmd = NULL;
    TileRect* _tileRects = NULL;

    int _width = 0;
    int _height = 0;
    int _tileCols = 0;
    int _tileRows = 0;
    int _tileTotal = 0;
    int _srcStride = 0;
    int _dstStride = 0;
    int _dstHeight = 0;
    size_t _srcMinSize = 0;
    size_t _tileDataSize = 0;
};

#endif /* PaintRFX_h */
