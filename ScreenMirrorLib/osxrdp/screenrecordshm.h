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
    int unused2;
    screenrecord_frame_t frames[FRAME_SLOTS];
    int screenrecord_data_size;
    char screenrecord_datas[1];
} screenrecord_shm_t;


#endif /* screenrecordshm_h */
