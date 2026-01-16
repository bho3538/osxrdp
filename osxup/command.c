#include "command.h"

#include "osxrdp/packet.h"

void _osxup_send_cmd(xipc_t* ipc, xstream_t* stream);

int osxup_send_start_cmd(xipc_t* ipc, int width, int height, int recordFormat) {
    xstream_t* stream = xstream_create(64);

    xstream_writeInt32(stream, OSXRDP_CMDTYPE_SCREEN);
    xstream_writeInt32(stream, OSXRDP_PACKETTYPE_REQ_SCREEN);
    xstream_writeInt32(stream, 0);              // display index 등
    xstream_writeInt32(stream, width);          // width
    xstream_writeInt32(stream, height);         // height
    xstream_writeInt32(stream, 60);             // fps
    xstream_writeInt32(stream, recordFormat);   // recordFormat (BGRA32, NV12)

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

void _osxup_send_cmd(xipc_t* ipc, xstream_t* stream) {
    int bufferLen = 0;
    const void* buffer = xstream_get_raw_buffer(stream, &bufferLen);

    xipc_send_data(ipc, buffer, bufferLen);
}
