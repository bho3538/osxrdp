
#ifndef egfx_h
#define egfx_h

#include "osxup.h"
#include "osxrdp/screenrecordshm.h"

void osxup_create_surface(struct mod* mod);

void osxup_start_frame(struct mod* mod, unsigned int frame_id);

void osxup_end_frame(struct mod* mod, unsigned int frame_id);

void osxup_draw_frame(struct mod* mod, unsigned int frame_id, screenrecord_frame_t* frameInfo, char* bitmapData, int bitmapDataLen);

#endif /* egfx_h */
