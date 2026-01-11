#ifndef paintscreen_h
#define paintscreen_h

#include "osxup.h"
#include "osxrdp/screenrecordshm.h"

void osxup_paint(struct mod* mod);
void osxup_paint_ack(screenrecord_shm_t* shm, int frame_id);

#endif /* paintscreen_h */
