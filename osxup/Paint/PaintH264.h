
#ifndef PaintH264_h
#define PaintH264_h

#include "PaintBase.h"
#include "xstream.h"

class PaintH264 : public PaintBase {
public:
    void Initialize(const struct mod* mod) override;
    void Release() override;
    void DoPaint(const struct mod* mod, screenrecord_frame_t* frameInfo, char* imgData, size_t imgDataSize, int frame_id, int displayId, int width, int height) override;

    // xrdp 가 이미지 데이터 소유권을 가져가므로 복사본을 만들어야 한다.
    bool NeedsOwnedPayload() const override { return true; }

    // 최신 프레임을 사용할 때는 건너뛴 프레임의 dirty를 병합한다.
    bool CanMergePendingFrames() const override { return true; }

    // 인코더·네트워크가 못 따라갈 때 지연이 늘지 않도록 설정
    int MaxInFlightFrames() const override { return 3; }
    
private:
    xstream_t* _drawCmd = NULL;
};


#endif /* PaintH264_h */
