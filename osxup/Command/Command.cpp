#include "../pch.h"
#include "Command.h"
#include "osxrdp/packet.h"

void Command::SendRecordStartMsg(xipc_t* agentIpc, int width, int height, int recordFormat, int useVirtualmon, int monitorCount, struct monitor_info* monitorInfo) {
    _SendScreenStartupMsg(agentIpc, OSXRDP_PACKETTYPE_REQ_SCREEN, width, height, recordFormat, useVirtualmon, monitorCount, monitorInfo);
}

void Command::SendResizeMsg(xipc_t* agentIpc, int width, int height, int recordFormat, int useVirtualmon, int monitorCount, struct monitor_info* monitorInfo) {
    _SendScreenStartupMsg(agentIpc, OSXRDP_PACKETTYPE_REQ_RESIZE, width, height, recordFormat, useVirtualmon, monitorCount, monitorInfo);
}

void Command::_SendScreenStartupMsg(xipc_t* agentIpc, int packetType, int width, int height, int recordFormat, int useVirtualmon, int monitorCount, struct monitor_info* monitorInfo) {
    assert(agentIpc != NULL);
    assert(width > 0);
    assert(height > 0);

    xstream_t* stream = xstream_create(1024);

    if (monitorCount > 16) {
        monitorCount = 1;
    }

    xstream_writeInt32(stream, OSXRDP_CMDTYPE_SCREEN);
    xstream_writeInt32(stream, packetType);
    xstream_writeInt32(stream, 0);              // display index 등 (unused)
    xstream_writeInt32(stream, width);          // width
    xstream_writeInt32(stream, height);         // height
    xstream_writeInt32(stream, 60);             // fps (unused)
    xstream_writeInt32(stream, recordFormat);   // recordFormat (BGRA32, NV12, RFX)
    xstream_writeInt32(stream, useVirtualmon);  // use virtual monitor (0, 1)

    if (monitorCount == 0) {
        xstream_writeInt32(stream, 1);
        xstream_writeInt32(stream, 0);
        xstream_writeInt32(stream, 0);
        xstream_writeInt32(stream, width);
        xstream_writeInt32(stream, height);
        xstream_writeInt32(stream, 1);
    }
    else {
        xstream_writeInt32(stream, monitorCount);

        for (int i = 0; i < monitorCount; i++) {
            xstream_writeInt32(stream, monitorInfo[i].left);
            xstream_writeInt32(stream, monitorInfo[i].top);
            xstream_writeInt32(stream, monitorInfo[i].right);
            xstream_writeInt32(stream, monitorInfo[i].bottom);
            xstream_writeInt32(stream, monitorInfo[i].is_primary);
        }
    }

    _SendMsg(agentIpc, stream);

    xstream_free(stream);
}

void Command::SendRecordStopMsg(xipc_t* agentIpc) {
    assert(agentIpc != NULL);

    xstream_t* stream = xstream_create(8);

    xstream_writeInt32(stream, OSXRDP_CMDTYPE_SCREEN);
    xstream_writeInt32(stream, OSXRDP_PACKETTYPE_REQ_SCREENOFF);

    _SendMsg(agentIpc, stream);

    xstream_free(stream);
}

void Command::SendFullFrameRequestMsg(xipc_t* agentIpc) {
    assert(agentIpc != NULL);

    xstream_t* stream = xstream_create(8);

    xstream_writeInt32(stream, OSXRDP_CMDTYPE_SCREEN);
    xstream_writeInt32(stream, OSXRDP_PACKETTYPE_REQ_FULLFRAME);

    _SendMsg(agentIpc, stream);

    xstream_free(stream);
}

void Command::SendMouseInputMsg(xipc_t* agentIpc, int inputType, short x, short y) {
    struct {
        int cmdType;
        int packetType;
        int inputType;
        int x;
        int y;
    } __attribute__((packed)) msg = {
        OSXRDP_CMDTYPE_SCREEN,
        OSXRDP_PACKETTYPE_MOUSEEVT,
        inputType,
        x,
        y
    };

    xipc_send_data(agentIpc, (void*)&msg, sizeof(msg));
}

void Command::SendKeyboardInputMsg(xipc_t* agentIpc, int inputType, int keycode, int flags) {
    struct {
        int cmdType;
        int packetType;
        int inputType;
        int keycode;
        int flags;
    } __attribute__((packed)) msg = {
        OSXRDP_CMDTYPE_SCREEN,
        OSXRDP_PACKETTYPE_KEYBOARDEVT,
        inputType,
        keycode,
        flags
    };

    xipc_send_data(agentIpc, (void*)&msg, sizeof(msg));
}

void Command::SendSessionRequestMsg(xipc_t* sessionIpc, const char* username, int usernameLen) {
    assert(sessionIpc != NULL);
    assert(username != NULL);

    xstream_t* stream = xstream_create(512);
    xstream_writeInt32(stream, OSXRDP_SESSMAN_REQUEST_SESSION);
    xstream_writeStr(stream, username, (int)usernameLen);

    _SendMsg(sessionIpc, stream);

    xstream_free(stream);
}

void Command::SendSessionReleaseMsg(xipc_t* sessionIpc, int sessionId) {
    assert(sessionIpc != NULL);

    xstream_t* stream = xstream_create(8);
    xstream_writeInt32(stream, OSXRDP_SESSMAN_REQUEST_RELEASESESSION);
    xstream_writeInt32(stream, sessionId);

    _SendMsg(sessionIpc, stream);

    xstream_free(stream);
}

void Command::SendClipboardMsg(xipc_t* agentIpc, int channelId, int channelFlags, const char* data, int dataLen, int totalLen) {
    assert(agentIpc != NULL);

    xstream_t* stream = xstream_create(dataLen + sizeof(int) * 6);

    xstream_writeInt32(stream, OSXRDP_CMDTYPE_CLIPBOARD);
    xstream_writeInt32(stream, OSXRDP_PACKETTYPE_REQ_SETCLIENTCLIP);
    xstream_writeInt32(stream, channelId);
    xstream_writeInt32(stream, channelFlags);
    xstream_writeInt32(stream, totalLen);
    xstream_writeInt32(stream, dataLen);
    xstream_writeData(stream, (void*)data, dataLen);

    _SendMsg(agentIpc, stream);

    xstream_free(stream);
}

void Command::SendAudioMsg(xipc_t* agentIpc, int channelId, int channelFlags, const char* data, int dataLen, int totalLen) {
    assert(agentIpc != NULL);

    xstream_t* stream = xstream_create(dataLen + sizeof(int) * 6);

    xstream_writeInt32(stream, OSXRDP_CMDTYPE_AUDIO);
    xstream_writeInt32(stream, OSXRDP_PACKETTYPE_REQ_SETCLIENTAUDIO);
    xstream_writeInt32(stream, channelId);
    xstream_writeInt32(stream, channelFlags);
    xstream_writeInt32(stream, totalLen);
    xstream_writeInt32(stream, dataLen);
    xstream_writeData(stream, (void*)data, dataLen);

    _SendMsg(agentIpc, stream);

    xstream_free(stream);
}

void Command::SendAudioReadyMsg(xipc_t* agentIpc) {
    assert(agentIpc != NULL);

    xstream_t* stream = xstream_create(8);
    xstream_writeInt32(stream, OSXRDP_CMDTYPE_AUDIO);
    xstream_writeInt32(stream, OSXRDP_PACKETTYPE_AUDIO_READY);

    _SendMsg(agentIpc, stream);

    xstream_free(stream);
}

void Command::_SendMsg(xipc_t* ipc, xstream_t* stream) {
    assert(stream != NULL);

    int bufferLen = 0;
    const void* buffer = xstream_get_raw_buffer(stream, &bufferLen);

    xipc_send_data(ipc, buffer, bufferLen);
}
