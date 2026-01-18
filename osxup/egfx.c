
#include "egfx.h"
#include "xstream.h"

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

void _osxup_send_egfx_cmd(struct mod* mod, char* cmd, int cmd_bytes);
void _osxup_send_egfx_cmd_with_data(struct mod* mod, char* cmd, int cmd_bytes, char* data, int data_len);

void osxup_create_surface(struct mod* mod) {
    
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
    
    _osxup_send_egfx_cmd(mod, (char*)&reset, sizeof(reset));
    
    XRDP_EGFX_CREATE_SURFACE cmd;
    cmd.header.cmdId = 0x0009;
    cmd.header.flags = 0;
    cmd.header.pduLength = sizeof(cmd);
    
    cmd.surfaceId = 0;
    cmd.width = mod->width;
    cmd.height = mod->height;
    cmd.fmt = 0x20;
    
    _osxup_send_egfx_cmd(mod, (char*)&cmd, sizeof(cmd));
    
    XRDP_EGFX_MAP_SURFACE_TO_OUTPUT output;
    output.header.cmdId = 0x0F;
    output.header.flags = 0;
    output.header.pduLength = sizeof(output);
    
    output.surfaceId = 0;
    output.outputX = 0;
    output.outputY = 0;
    
    _osxup_send_egfx_cmd(mod, (char*)&output, sizeof(output));
}

void osxup_start_frame(struct mod* mod, unsigned int frame_id) {
    XRDP_EGFX_START_FRAME cmd;
    
    cmd.header.cmdId = 11;
    cmd.header.flags = 0;
    cmd.header.pduLength = sizeof(cmd);
    cmd.timestamp = 0;
    cmd.frame_id = frame_id;
    
    _osxup_send_egfx_cmd(mod, (char*)&cmd, sizeof(cmd));
}

void osxup_end_frame(struct mod* mod, unsigned int frame_id) {
    XRDP_EGFX_END_FRAME cmd;
    cmd.header.cmdId = 12;
    cmd.header.flags = 0;
    cmd.header.pduLength = sizeof(cmd);
    cmd.frame_id = frame_id;
    
    _osxup_send_egfx_cmd(mod, (char*)&cmd, sizeof(cmd));
}

void osxup_draw_frame(struct mod* mod, unsigned int frame_id, screenrecord_frame_t* frameInfo, char* bitmapData, int bitmapDataLen) {
    xstream_t* cmd = mod->msgs.paint_msg;
    
    xstream_resetPos(cmd);
    
    // header
    xstream_writeInt16(cmd, 0x1); // cmdId
    xstream_writeInt16(cmd, 0); // flags
    xstream_writeInt32(cmd, 0); // len
    
    // body
    xstream_writeInt16(cmd, 0); // surface_id;
    xstream_writeInt16(cmd, 0x000B); // codec_id;
    xstream_writeInt8(cmd, 0x20); // pixel_format (BGRA)
    xstream_writeInt32(cmd, 0); // flags?
    
    char* rects_start_ptr = cmd->data_current;
    
    // rects
    if (frameInfo->dirtyCount > 0) {
        xstream_writeInt16(cmd, frameInfo->dirtyCount); // num_rects
        
        for (int i = 0; i < frameInfo->dirtyCount; i++) {
            xstream_writeInt16(cmd, frameInfo->dirtys[i].x);
            xstream_writeInt16(cmd, frameInfo->dirtys[i].y);
            xstream_writeInt16(cmd, frameInfo->dirtys[i].width);
            xstream_writeInt16(cmd, frameInfo->dirtys[i].height);
        }
    }
    else {
        xstream_writeInt16(cmd, 1); // num_rects

        //xstream_writeInt16(cmd, 0);
        //xstream_writeInt16(cmd, 0);
        xstream_writeInt32(cmd, 0);
        xstream_writeInt16(cmd, mod->width);
        xstream_writeInt16(cmd, mod->height);
    }
    
    // 한번 더 복사 (그대로)
    int rects_data_len = (int)((char*)cmd->data_current - rects_start_ptr);
    memcpy(cmd->data_current, rects_start_ptr, rects_data_len);
    cmd->data_current += rects_data_len;
    
    //xstream_writeInt16(cmd, 0);
    //xstream_writeInt16(cmd, 0);
    xstream_writeInt32(cmd, 0);
    xstream_writeInt16(cmd, mod->width);
    xstream_writeInt16(cmd, mod->height);
    
    int dataLen = (int)(cmd->data_current - cmd->data_start);
    
    *(int*)((char*)cmd->data_start + sizeof(int)) = dataLen;

    _osxup_send_egfx_cmd_with_data(mod, (char*)cmd->data_start, dataLen, bitmapData, bitmapDataLen);
}

void _osxup_send_egfx_cmd(struct mod* mod, char* cmd, int cmd_bytes) {
    mod->server_egfx_cmd(mod, cmd, cmd_bytes, NULL, 0);
}

void _osxup_send_egfx_cmd_with_data(struct mod* mod, char* cmd, int cmd_bytes, char* data, int data_len) {
    mod->server_egfx_cmd(mod, cmd, cmd_bytes, data, data_len);
}
