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
    virtual void DoPaint(const struct mod* mod, screenrecord_frame_t* frameInfo, char* imgData, size_t imgDataSize, int frame_id, int displayId, int width, int height) = 0;

    // shm의 슬롯에 담긴 프레임이 전체 frame 인지 / 일부 변경점만 포함하는지의 여부
    //   - BGRA32 / NV12 : slot = 전체 frame 이미지       → true  (기본값)
    //   - RFX           : slot = "이번에 변경된 타일"만   → false
    virtual bool FrameIsSelfContained() const { return true; }
};

#endif
