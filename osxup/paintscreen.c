#include "paintscreen.h"

#include "egfx.h"

int _osxup_paint_get_data(screenrecord_shm_t* shm, screenrecord_frame_t** outFrameInfo, char** outImgData, size_t* outImgDataSize, unsigned int* frame_id);

void osxup_paint(struct mod* mod) {
    struct xrdp_rect {
        short x;
        short y;
        short cx;
        short cy;
    };
    
    // 화면 데이터가 저장되어있는 공유 메모리
    screenrecord_shm_t* shm = (screenrecord_shm_t*)mod->screenShm->mem;
    
    screenrecord_frame_t* frameInfo = NULL;
    char* imgData = NULL;
    size_t imgDataSize = 0;
    unsigned int frame_id = 0;
    
    // ScreenRecorder --> agent --> osxup 까지 데이터가 오는대 처리 지연이 발생하는것 같음 (밀리는 데이터가 점점 생김)
    // 따라서 한번 처리할때 2~3번씩 그려주니 이러한 현상이 많이 줄어드는것 같음
    // 깔끔한 방식은 아니라서 이렇게 해도 될지 고민....
    for (int i = 0; i < 3; i++) {
        // 읽을 화면 데이터가 있는지 확인
        if (_osxup_paint_get_data(shm, &frameInfo, &imgData, &imgDataSize, &frame_id) == 0) {
            return;
        }
        
        if (mod->client_info.gfx) {
            // using GFX
            osxup_start_frame(mod, frame_id);
            
            osxup_draw_frame(mod, frame_id, frameInfo, (char*)imgData, (int)imgDataSize);
            
            osxup_end_frame(mod, frame_id);
        }
        else {
            // using legacy bitmap
            mod->server_begin_update(mod);
                
            if (frameInfo->dirtyCount > 0 && frameInfo->dirtyCount < MAX_DIRTY_COUNT) {
                struct xrdp_rect dirtys[MAX_DIRTY_COUNT];
                
                // dirty area 정보를 담기
                for (int i = 0; i < frameInfo->dirtyCount; i++) {
                    dirtys[i].x = (short)frameInfo->dirtys[i].x;
                    dirtys[i].y = (short)frameInfo->dirtys[i].y;
                    dirtys[i].cx = (short)frameInfo->dirtys[i].width;
                    dirtys[i].cy = (short)frameInfo->dirtys[i].height;
                }
                
                mod->server_paint_rects(mod, frameInfo->dirtyCount, (short*)dirtys, frameInfo->dirtyCount, (short*)dirtys, imgData, mod->width, mod->height, 0 ,frame_id);
            }
            else {
                // full draw
                struct xrdp_rect dummy = {0, 0, mod->width, mod->height};
                mod->server_paint_rects(mod, 1, (short*)&dummy, 1, (short*)&dummy, imgData, mod->width, mod->height, 0 ,frame_id);
            }
                
            mod->server_end_update(mod);
        }
        
        if (frameInfo->cursor_data.updated != 0) {
            mod->server_set_pointer_large(mod, frameInfo->cursor_data.hotspotX, frameInfo->cursor_data.hotspotY, frameInfo->cursor_data.cursorImgData, frameInfo->cursor_data.cursorImgMask, 32, frameInfo->cursor_data.width, frameInfo->cursor_data.height);
        }
    }
}

void osxup_paint_ack(screenrecord_shm_t* shm, int frame_id) {
    if (shm == NULL) return;
    
    unsigned int read_pos = atomic_load_explicit(&shm->read_pos,  memory_order_relaxed);
    unsigned int write_pos = atomic_load_explicit(&shm->write_pos, memory_order_acquire);

    if (write_pos - read_pos >= FRAME_SLOTS) {
        atomic_store_explicit(&shm->read_pos, read_pos + FRAME_SLOTS, memory_order_release);
    }
    else {
        atomic_store_explicit(&shm->read_pos, read_pos + 1, memory_order_release);
    }
}

int _osxup_paint_get_data(screenrecord_shm_t* shm, screenrecord_frame_t** outFrameInfo, char** outImgData, size_t* outImgDataSize, unsigned int* frame_id) {
    // 읽을 데이터가 있는지 확인
    unsigned int read_pos = atomic_load_explicit(&shm->read_pos,  memory_order_relaxed);
    unsigned int write_pos = atomic_load_explicit(&shm->write_pos, memory_order_acquire);
    
    if (read_pos == write_pos) {
        return 0;
    }
    
    int forceRedrawAll = 0;
    if (write_pos - read_pos >= FRAME_SLOTS) {
        read_pos = write_pos - 1;
        forceRedrawAll = 1;
    }
    
    unsigned int idx = read_pos % FRAME_SLOTS;
    screenrecord_frame_t* frame = &(shm->frames[idx]);
    char* imgData = *(&shm->screenrecord_datas + (size_t)shm->screenrecord_data_size * idx);
    
    size_t imgDataSize = 0;
    memcpy(&imgDataSize, imgData, sizeof(size_t));
    
    // abnormal data --> skip it
    if (imgDataSize == 0 || imgDataSize > shm->screenrecord_data_size)
        return 0;
    
    if (forceRedrawAll != 0) {
        frame->dirtyCount = 0;
    }
        
    *outFrameInfo = frame;
    *outImgData = imgData + sizeof(size_t);
    *outImgDataSize = imgDataSize;
    
    *frame_id = read_pos;
    
    atomic_store_explicit(&shm->read_pos, read_pos + 1, memory_order_release);
    
    return 1;
}

