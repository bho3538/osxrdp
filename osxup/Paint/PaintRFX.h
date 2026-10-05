#ifndef PaintRFX_h
#define PaintRFX_h

#include "PaintBase.h"
#include "xstream.h"

class PaintRFX : public PaintBase {
public:
    PaintRFX();
    void Initialize(const struct mod* mod);
    void Release();
    void DoPaint(const struct mod* mod, screenrecord_frame_t* frameInfo, char* imgData, size_t imgDataSize, int frame_id, int displayId, int width, int height);

    // 최신 프레임을 사용할 때는 건너뛴 프레임의 dirty를 병합한다.
    bool CanMergePendingFrames() const { return true; }

    // 인코더·네트워크가 못 따라갈 때 지연이 늘지 않도록 설정
    int MaxInFlightFrames() const { return 2; }

private:

    struct TileData {
        RECT rect;
        size_t srcOffset;
        size_t dstOffset;
    };

    struct DisplayData {
        int valid;
        int width;
        int height;
        int tileCols;
        int tileRows;
        int tileTotal;
        size_t dataSize;
        TileData* tiles;
        bool* selected;
        int* tileIndices;
        bool frameSubmitted;
    };

    // 타일 선택·복사·명령 작성을 수행하고 프레임을 XRDP에 제출한다.
    bool SubmitFrame(const struct mod* mod, screenrecord_frame_t* frameInfo, char* imgData, size_t imgDataSize, int frame_id, int displayId, int width, int height);
    // dirty 영역을 정리하고 중복 없는 타일 목록을 만든 뒤 선택 표시를 해제한다.
    int SelectTiles(DisplayData* display, const screenrecord_frame_t* frameInfo, screenrecord_frame_t* dirtyFrame);
    // 선택된 타일의 YUV 데이터를 전송 버퍼에 재배열한다.
    void CopyTiles(const DisplayData* display, const char* imgData, char* data, int tileCount);
    // 프레임 시작·타일 전송·종료 명령을 작성하고 전체 명령 크기를 반환한다.
    int WriteCommands(const DisplayData* display, const screenrecord_frame_t* dirtyFrame, int tileCount, int frame_id, int displayId);
    // 타일 하나의 packed Cr/Y/Cb 데이터를 64x64 planar Y/U/V로 재배열한다.
    void CopyRFXTile(const unsigned char* src, int stride, unsigned char* dst, int width, int height);
    // 사각형 개수와 각 사각형의 좌표·크기를 명령 스트림에 기록한다.
    void WriteRFXRects(xstream_t* stream, const RECT* rects, int count);

    xstream_t* _drawCmd;
    DisplayData _displays[16];
};

#endif /* PaintRFX_h */
