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
    struct TileRect {
        short left;
        short top;
        short width;
        short height;
    };

    xstream_t* _drawCmd = NULL;
    unsigned char* _tileMarks = NULL;
    int* _tileIndices = NULL;
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
