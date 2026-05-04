#include "../pch.h"
#include "PaintH264.h"
#include "../osxup.h"


typedef struct _XRDP_EFGX_CMD_HEADER {
    short cmdId;
    short flags;
    int pduLength; // header + body size
} __attribute__((packed)) XRDP_EFGX_CMD_HEADER;

typedef struct _XRDP_EGFX_CREATE_SURFACE {
    XRDP_EFGX_CMD_HEADER header;
    short surfaceId;
    short width;
    short height;
    char fmt;
} __attribute__((packed)) XRDP_EGFX_CREATE_SURFACE;

typedef struct _XRDP_EGFX_START_FRAME {
    XRDP_EFGX_CMD_HEADER header;
    int frame_id;
    int timestamp;
} __attribute__((packed)) XRDP_EGFX_START_FRAME;

typedef struct _XRDP_EGFX_END_FRAME {
    XRDP_EFGX_CMD_HEADER header;
    int frame_id;
} __attribute__((packed)) XRDP_EGFX_END_FRAME;

typedef struct _XRDP_EGFX_MAP_SURFACE_TO_OUTPUT {
    XRDP_EFGX_CMD_HEADER header;
    short surfaceId;
    int outputX;
    int outputY;
} __attribute__((packed)) XRDP_EGFX_MAP_SURFACE_TO_OUTPUT;

typedef struct _XRDP_EGFX_RESET_GRAPHICS_PDU {
    XRDP_EFGX_CMD_HEADER header;
    int width;
    int height;
    int monitor_count;
    // TODO : dynamic
    int left;
    int top;
    int right;
    int bottom;
    int is_primary;
} __attribute__((packed)) XRDP_EGFX_RESET_GRAPHICS_PDU;

void PaintH264::Initialize(const struct mod* mod) {
    /*
    XRDP_EGFX_RESET_GRAPHICS_PDU reset;
    reset.header.cmdId = 0x0E;
    reset.header.flags = 0;
    reset.header.pduLength = sizeof(reset);
    
    reset.width = mod->width;
    reset.height = mod->height;
    reset.monitor_count = 1;
    reset.top = 0;
    reset.left = 0;
    reset.right = mod->width;
    reset.bottom = mod->height;
    reset.is_primary = 1;
    
    mod->server_egfx_cmd((struct mod*)mod, (char*)&reset, sizeof(reset), NULL, 0);
    
    
    XRDP_EGFX_CREATE_SURFACE cmd;
    cmd.header.cmdId = 0x0009;
    cmd.header.flags = 0;
    cmd.header.pduLength = sizeof(cmd);
    
    cmd.surfaceId = 0;
    cmd.width = mod->width;
    cmd.height = mod->height;
    cmd.fmt = 0x20;
    
    mod->server_egfx_cmd((struct mod*)mod, (char*)&cmd, sizeof(cmd), NULL, 0);

    
    XRDP_EGFX_MAP_SURFACE_TO_OUTPUT output;
    output.header.cmdId = 0x0F;
    output.header.flags = 0;
    output.header.pduLength = sizeof(output);
    
    output.surfaceId = 0;
    output.outputX = 0;
    output.outputY = 0;
    
    mod->server_egfx_cmd((struct mod*)mod, (char*)&output, sizeof(output), NULL, 0);
     */
    
    _drawCmd = xstream_create(8192);
}

void PaintH264::Release() {
    if (_drawCmd != NULL) {
        xstream_free(_drawCmd);
        _drawCmd = NULL;
    }
}

void PaintH264::DoPaint(const struct mod* mod, screenrecord_frame_t* frameInfo, char* imgData, size_t imgDataSize, int frame_id, int displayId) {
    assert(mod != NULL);
    assert(frameInfo != NULL);
    assert(imgData != NULL);
    
    XRDP_EGFX_START_FRAME startCmd;
    startCmd.header.cmdId = 11;
    startCmd.header.flags = 0;
    startCmd.header.pduLength = sizeof(startCmd);
    startCmd.timestamp = 0;
    startCmd.frame_id = frame_id;
    
    mod->server_egfx_cmd((struct mod*)mod, (char*)&startCmd, sizeof(startCmd), NULL, 0);
    
    xstream_resetPos(_drawCmd);
    
    // header
    xstream_writeInt16(_drawCmd, 0x1);       // cmdId
    xstream_writeInt16(_drawCmd, 0);         // flags
    xstream_writeInt32(_drawCmd, 0);         // len
    
    // body
    xstream_writeInt16(_drawCmd, displayId); // surface_id;
    xstream_writeInt16(_drawCmd, 0x000B);    // codec_id;
    xstream_writeInt8(_drawCmd, 0x20);       // pixel_format (BGRA)
    xstream_writeInt32(_drawCmd, 0);         // flags?
    
    char* rects_start_ptr = (char*)_drawCmd->data_current;
    
    // rects
    if (frameInfo->dirtyCount > 0 && frameInfo->dirtyCount < MAX_DIRTY_COUNT) {
        xstream_writeInt16(_drawCmd, frameInfo->dirtyCount); // num_rects
        
        for (int i = 0; i < frameInfo->dirtyCount; i++) {
            xstream_writeInt16(_drawCmd, frameInfo->dirtys[i].x);
            xstream_writeInt16(_drawCmd, frameInfo->dirtys[i].y);
            xstream_writeInt16(_drawCmd, frameInfo->dirtys[i].width);
            xstream_writeInt16(_drawCmd, frameInfo->dirtys[i].height);
        }
    }
    else {
        xstream_writeInt16(_drawCmd, 1); // num_rects

        xstream_writeInt32(_drawCmd, 0);
        xstream_writeInt16(_drawCmd, mod->width);
        xstream_writeInt16(_drawCmd, mod->height);
    }
    
    // 한번 더 복사 (그대로)
    int rects_data_len = (int)((char*)_drawCmd->data_current - rects_start_ptr);
    xstream_writeData(_drawCmd, rects_start_ptr, rects_data_len);
    
    xstream_writeInt32(_drawCmd, 0);
    xstream_writeInt16(_drawCmd, mod->width);
    xstream_writeInt16(_drawCmd, mod->height);
    
    int dataLen = (int)((char*)_drawCmd->data_current - (char*)_drawCmd->data_start);
    
    *(int*)((char*)_drawCmd->data_start + sizeof(int)) = dataLen;

    mod->server_egfx_cmd((struct mod*)mod, (char*)_drawCmd->data_start, dataLen, imgData, (int)imgDataSize);

    XRDP_EGFX_END_FRAME endCmd;
    endCmd.header.cmdId = 12;
    endCmd.header.flags = 0;
    endCmd.header.pduLength = sizeof(endCmd);
    endCmd.frame_id = frame_id;
    
    mod->server_egfx_cmd((struct mod*)mod, (char*)&endCmd, sizeof(endCmd), NULL, 0);
}
