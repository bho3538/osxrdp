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

    // 최신 슬롯으로 건너뛸 때 미제출 프레임의 dirty를 병합할 수 있는지 여부.
    //   - true  : 항상 최신 슬롯을 쓰고 건너뛴 프레임의 dirty를 병합 (RFX)
    //   - false : backlog 일 때만 최신 슬롯으로 점프하고 full redraw(BGRA32 / NV12)
    virtual bool CanMergePendingFrames() const { return false; }

    // shm (이미지 데이터) 소유권이 xrdp로 넘어가는지 여부
    //   - true  : PaintManager 가 slot 을 mmap 하고 소유권을 xrdp로 넘긴다 (xrdp가 mumap)
    //   - false : xrdp 가 shm을 읽기만 함
    virtual bool NeedsOwnedPayload() const { return false; }

    // 제출할 수 있는 최대 프레임 수 (디스플레이 당, ACK 대기 포함)
    virtual int MaxInFlightFrames() const { return FRAME_SLOTS; }
};

#endif
