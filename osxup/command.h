#ifndef command_h
#define command_h

#include "xstream.h"
#include "ipc.h"

int osxup_send_start_cmd(xipc_t* ipc, int width, int height, int recordFormat, int useVirtualmon);
int osxup_send_stop_cmd(xipc_t* ipc);

int osxup_send_input(xstream_t* stream, xipc_t* ipc, int inputType, short x, short y);
int osxup_send_keyboard_input(xstream_t* stream, xipc_t* ipc, int inputType, int keycode, int flags);

int osxup_send_sessionrequest(xipc_t* ipc, const char* username);
int osxup_send_sessionrelease(xipc_t* ipc, int sessionId);

void osxup_check_alive(xipc_t* ipc);

#endif /* command_h */
