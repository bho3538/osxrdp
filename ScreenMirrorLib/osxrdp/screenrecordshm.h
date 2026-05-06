#ifndef screenrecordshm_h
#define screenrecordshm_h

#include <stdint.h>
#include <stdatomic.h>

#include <CoreFoundation/CoreFoundation.h>
#include "xshm.h"

#define FRAME_SLOTS             8
#define MAX_DIRTY_COUNT         128

struct RECT {
    short x;
    short y;
    short width;
    short height;
};

#define MAX_CURSOR_IMG_BUFFER_SIZE (128 * 128)

typedef struct cursor_data {
    _Atomic int updated;
    int width;
    int height;
    int hotspotX;
    int hotspotY;
    int cursorImgDataSize;
    char cursorImgData[MAX_CURSOR_IMG_BUFFER_SIZE * 4]; //BGRA
    char cursorMaskData[MAX_CURSOR_IMG_BUFFER_SIZE]; //mask (dummy)
} cursor_data_t;

typedef struct screenrecord_frame {
    int dirtyCount;  // <--- 이것이 0일 경우 full redraw
    struct RECT dirtys[MAX_DIRTY_COUNT];
} screenrecord_frame_t;

typedef struct screenrecord_shm {
    _Atomic unsigned int write_pos;
    _Atomic unsigned int read_pos;
    int width;
    int height;
    int fps;
    // osxup 가 full redraw 를 해야할 경우 ServerApp 에게 full frame 을 채워 달라는 신호. (RFX (partial frame 지원) 에서만 사용)
    _Atomic int consumer_request_full;
    screenrecord_frame_t frames[FRAME_SLOTS];
    int screenrecord_data_size;
    char screenrecord_datas[1];
} screenrecord_shm_t;

// ---------------------------------------------------------------------------
// RFX dirty-only SHM slot 레이아웃 (recordFormat == OSXRDP_RECORDFORMAT_RFX)
// ---------------------------------------------------------------------------
//   offset 0             : size_t imgSize
//                            = sizeof(int)                              // tileCount
//                            + sizeof(int) * tileCount                  // indices
//                            + 16384 * tileCount                        // tile payload
//   offset sizeof(size_t): int tileCount                                // 이 slot 에 포함된 tile 개수
//   이어서               : int indices[tileCount]                       // row-major 전역 tile 인덱스
//   이어서               : uint8_t tileData[tileCount * 16384]          // YUV444 planar (Y, U, V, A)
//
// tileCount 가 해당 프레임의 전체 tile 개수 (tileCols * tileRows) 와 같으면
// full redraw 프레임이다. 그보다 작으면 dirty-only 프레임.
// ---------------------------------------------------------------------------
#define OSXRDP_RFX_TILE_BYTES (16384)  // 64 x 64 x (Y + U + V + A)


#endif /* screenrecordshm_h */
