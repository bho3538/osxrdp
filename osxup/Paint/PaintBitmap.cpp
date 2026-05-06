#include "../pch.h"
#include "PaintBitmap.h"
#include "../osxup.h"

struct xrdp_rect {
    short x;
    short y;
    short cx;
    short cy;
};

void PaintBitmap::Initialize(const struct mod* mod)
{}

void PaintBitmap::Release()
{}

void PaintBitmap::DoPaint(const struct mod* mod, screenrecord_frame_t* frameInfo, char* imgData, size_t imgDataSize, int frame_id, int displayId, int width, int height) {
    assert(mod != NULL);
    assert(frameInfo != NULL);
    assert(imgData != NULL);
    
    (void)displayId; // unused
    (void)width;     // unused
    (void)height;    // unused
    
    mod->server_begin_update((struct mod*)mod);
        
    if (frameInfo->dirtyCount > 0 && frameInfo->dirtyCount < MAX_DIRTY_COUNT) {
        struct xrdp_rect dirtys[MAX_DIRTY_COUNT];
        
        // dirty area 정보를 담기
        for (int i = 0; i < frameInfo->dirtyCount; i++) {
            dirtys[i].x = (short)frameInfo->dirtys[i].x;
            dirtys[i].y = (short)frameInfo->dirtys[i].y;
            dirtys[i].cx = (short)frameInfo->dirtys[i].width;
            dirtys[i].cy = (short)frameInfo->dirtys[i].height;
        }
        
        mod->server_paint_rects((struct mod*)mod, frameInfo->dirtyCount, (short*)dirtys, frameInfo->dirtyCount, (short*)dirtys, imgData, mod->width, mod->height, 0 ,frame_id);
    }
    else {
        // full draw
        struct xrdp_rect dummy = {0, 0, (short)mod->width, (short)mod->height};
        
        mod->server_paint_rects((struct mod*)mod, 1, (short*)&dummy, 1, (short*)&dummy, imgData, mod->width, mod->height, 0 ,frame_id);
    }
        
    mod->server_end_update((struct mod*)mod);
}
