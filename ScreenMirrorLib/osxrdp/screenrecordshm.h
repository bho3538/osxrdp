#ifndef screenrecordshm_h
#define screenrecordshm_h

#include <stdint.h>
#include <stdatomic.h>

#include <CoreFoundation/CoreFoundation.h>
#include "xshm.h"

#define FRAME_SLOTS             4
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
    int unused;
    screenrecord_frame_t frames[FRAME_SLOTS];
    int screenrecord_data_size;
    char screenrecord_datas[1];
} screenrecord_shm_t;


#endif /* screenrecordshm_h */
