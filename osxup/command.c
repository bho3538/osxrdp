#include "command.h"

#include "osxrdp/packet.h"

#include <string.h>

void _osxup_send_cmd(xipc_t* ipc, xstream_t* stream);

int osxup_send_start_cmd(xipc_t* ipc, int width, int height, int recordFormat, int useVirtualmon) {
    xstream_t* stream = xstream_create(64);

    xstream_writeInt32(stream, OSXRDP_CMDTYPE_SCREEN);
    xstream_writeInt32(stream, OSXRDP_PACKETTYPE_REQ_SCREEN);
    xstream_writeInt32(stream, 0);              // display index 등
    xstream_writeInt32(stream, width);          // width
    xstream_writeInt32(stream, height);         // height
    xstream_writeInt32(stream, 60);             // fps
    xstream_writeInt32(stream, recordFormat);   // recordFormat (BGRA32, NV12)
    xstream_writeInt32(stream, useVirtualmon);  // use virtual monitor (0, 1)

    _osxup_send_cmd(ipc, stream);

    xstream_free(stream);
    
    return 0;
}

int osxup_send_stop_cmd(xipc_t* ipc) {
    xstream_t* stream = xstream_create(16);

    xstream_writeInt32(stream, OSXRDP_CMDTYPE_SCREEN);
    xstream_writeInt32(stream, OSXRDP_PACKETTYPE_REQ_SCREENOFF);

    _osxup_send_cmd(ipc, stream);

    xstream_free(stream);
    
    return 0;
}

int osxup_send_input(xstream_t* stream, xipc_t* ipc, int inputType, short x, short y) {
    xstream_resetPos(stream);
    
    xstream_writeInt32(stream, OSXRDP_CMDTYPE_SCREEN);
    xstream_writeInt32(stream, OSXRDP_PACKETTYPE_MOUSEEVT);
    xstream_writeInt32(stream, inputType);
    xstream_writeInt32(stream, x);
    xstream_writeInt32(stream, y);

    _osxup_send_cmd(ipc, stream);

    
    return 0;
}

int osxup_send_keyboard_input(xstream_t* stream, xipc_t* ipc, int inputType, int keycode, int flags) {
    xstream_resetPos(stream);

    xstream_writeInt32(stream, OSXRDP_CMDTYPE_SCREEN);
    xstream_writeInt32(stream, OSXRDP_PACKETTYPE_KEYBOARDEVT);
    xstream_writeInt32(stream, inputType);
    xstream_writeInt32(stream, keycode);
    xstream_writeInt32(stream, flags);

    _osxup_send_cmd(ipc, stream);
    
    return 0;
}

int osxup_send_sessionrequest(xipc_t* ipc, const char* username) {
    xstream_t* stream = xstream_create(512);

    xstream_writeInt32(stream, OSXRDP_SESSMAN_REQUEST_SESSION);
    xstream_writeStr(stream, username, (int)strlen(username) + 1);

    _osxup_send_cmd(ipc, stream);

    xstream_free(stream);
    
    return 0;
}

int osxup_send_sessionrelease(xipc_t* ipc, int sessionId) {
    xstream_t* stream = xstream_create(16);

    xstream_writeInt32(stream, OSXRDP_SESSMAN_REQUEST_RELEASESESSION);
    xstream_writeInt32(stream, sessionId);

    _osxup_send_cmd(ipc, stream);

    xstream_free(stream);
    
    return 0;
}

void osxup_check_alive(xipc_t* ipc) {
    int dummy = 0xffff;
    xipc_send_data(ipc, &dummy, sizeof(int));
}

void _osxup_send_cmd(xipc_t* ipc, xstream_t* stream) {
    int bufferLen = 0;
    const void* buffer = xstream_get_raw_buffer(stream, &bufferLen);

    xipc_send_data(ipc, buffer, bufferLen);
}
