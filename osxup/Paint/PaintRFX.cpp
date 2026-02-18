#include "../pch.h"
#include "PaintRFX.h"
#include "../osxup.h"
#include <sys/mman.h>

static const short XR_RDPGFX_CMDID_WIRETOSURFACE_2 = 0x0002;
static const short XR_RDPGFX_CODECID_CAPROGRESSIVE = 0x0009;
static const char XR_PIXEL_FORMAT_XRGB_8888 = 0x20;

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

static inline int
clamp_int(int value, int min_value, int max_value)
{
    if (value < min_value)
    {
        return min_value;
    }
    if (value > max_value)
    {
        return max_value;
    }
    return value;
}

static inline unsigned char
clamp_u8(int value)
{
    if (value < 0)
    {
        return 0;
    }
    if (value > 255)
    {
        return 255;
    }
    return (unsigned char)value;
}

// BGRA 픽셀을 YUV444 로 변환
static inline void
bgra_to_yuv709(unsigned char b, unsigned char g, unsigned char r,
               unsigned char* y, unsigned char* u, unsigned char* v)
{
    int iy = ((54 * (int)r + 183 * (int)g + 18 * (int)b + 128) >> 8);
    int iu = (((-29 * (int)r - 99 * (int)g + 128 * (int)b + 128) >> 8) + 128);
    int iv = (((128 * (int)r - 116 * (int)g - 12 * (int)b + 128) >> 8) + 128);
    *y = clamp_u8(iy);
    *u = clamp_u8(iu);
    *v = clamp_u8(iv);
}

void PaintRFX::Initialize(const struct mod* mod) {
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
    
    XRDP_EGFX_CREATE_SURFACE createSurface;
    createSurface.header.cmdId = 0x0009;
    createSurface.header.flags = 0;
    createSurface.header.pduLength = sizeof(createSurface);
    
    createSurface.surfaceId = 0;
    createSurface.width = mod->width;
    createSurface.height = mod->height;
    createSurface.fmt = 0x20;
    
    mod->server_egfx_cmd((struct mod*)mod, (char*)&createSurface, sizeof(createSurface), NULL, 0);
    
    XRDP_EGFX_MAP_SURFACE_TO_OUTPUT output;
    output.header.cmdId = 0x0F;
    output.header.flags = 0;
    output.header.pduLength = sizeof(output);
    
    output.surfaceId = 0;
    output.outputX = 0;
    output.outputY = 0;
    
    mod->server_egfx_cmd((struct mod*)mod, (char*)&output, sizeof(output), NULL, 0);
    
    _drawCmd = xstream_create(512 * 1024);
}

void PaintRFX::Release() {
    if (_drawCmd != NULL) {
        xstream_free(_drawCmd);
        _drawCmd = NULL;
    }
}

void PaintRFX::DoPaint(const struct mod* mod, screenrecord_frame_t* frameInfo, char* imgData, size_t imgDataSize, int frame_id) {
    assert(mod != NULL);
    assert(frameInfo != NULL);
    assert(imgData != NULL);
    assert(_drawCmd != NULL);
    
    xstream_resetPos(_drawCmd);
    
    // header
    xstream_writeInt16(_drawCmd, XR_RDPGFX_CMDID_WIRETOSURFACE_2); // cmdId
    xstream_writeInt16(_drawCmd, 0);        // flags
    xstream_writeInt32(_drawCmd, 0);        // len
    
    // body
    xstream_writeInt16(_drawCmd, 0);                        // surface_id
    xstream_writeInt16(_drawCmd, XR_RDPGFX_CODECID_CAPROGRESSIVE); // codec_id
    xstream_writeInt32(_drawCmd, 0);                        // codec_context_id
    xstream_writeInt8(_drawCmd, XR_PIXEL_FORMAT_XRGB_8888); // pixel_format
    xstream_writeInt32(_drawCmd, 0);                        // flags
    
    const int tileCols = (mod->width + 63) / 64;
    const int tileRows = (mod->height + 63) / 64;
    const int tileTotal = tileCols * tileRows;
    if (tileCols <= 0 || tileRows <= 0 || tileTotal <= 0) {
        return;
    }
    unsigned char* tileMarks = (unsigned char*)calloc((size_t)tileTotal, 1);
    if (tileMarks == NULL) {
        return;
    }
    
    if (frameInfo->dirtyCount > 0 && frameInfo->dirtyCount < MAX_DIRTY_COUNT) {
        for (int i = 0; i < frameInfo->dirtyCount; i++) {
            int x0 = frameInfo->dirtys[i].x;
            int y0 = frameInfo->dirtys[i].y;
            int x1 = x0 + frameInfo->dirtys[i].width;
            int y1 = y0 + frameInfo->dirtys[i].height;
            
            x0 = clamp_int(x0, 0, mod->width);
            y0 = clamp_int(y0, 0, mod->height);
            x1 = clamp_int(x1, 0, mod->width);
            y1 = clamp_int(y1, 0, mod->height);
            if (x1 <= x0 || y1 <= y0) {
                continue;
            }
            
            int tx0 = x0 / 64;
            int ty0 = y0 / 64;
            int tx1 = (x1 - 1) / 64;
            int ty1 = (y1 - 1) / 64;
            for (int ty = ty0; ty <= ty1; ty++) {
                for (int tx = tx0; tx <= tx1; tx++) {
                    tileMarks[(size_t)ty * (size_t)tileCols + (size_t)tx] = 1;
                }
            }
        }
    } else {
        memset(tileMarks, 1, (size_t)tileTotal);
    }
    
    int tileCount = 0;
    for (int i = 0; i < tileTotal; i++) {
        if (tileMarks[(size_t)i] != 0) {
            tileCount++;
        }
    }
    if (tileCount <= 0) {
        memset(tileMarks, 1, (size_t)tileTotal);
        tileCount = tileTotal;
    }
    
    if (tileCount <= 0) {
        free(tileMarks);
        return;
    }
    
    // RFX progressive 처리를 위해 정렬된 (64) dirty area 를 설정
    xstream_writeInt16(_drawCmd, tileCount); // num_rects_d
    for (int ty = 0; ty < tileRows; ty++) {
        for (int tx = 0; tx < tileCols; tx++) {
            if (tileMarks[(size_t)ty * (size_t)tileCols + (size_t)tx] == 0) {
                continue;
            }
            
            int left = tx * 64;
            int top = ty * 64;
            int width = (mod->width - left < 64) ? (mod->width - left) : 64;
            int height = (mod->height - top < 64) ? (mod->height - top) : 64;
            if (width <= 0 || height <= 0) {
                continue;
            }
            
            xstream_writeInt16(_drawCmd, (short)left);
            xstream_writeInt16(_drawCmd, (short)top);
            xstream_writeInt16(_drawCmd, (short)width);
            xstream_writeInt16(_drawCmd, (short)height);
        }
    }
    
    xstream_writeInt16(_drawCmd, tileCount); // num_rects_c
    for (int ty = 0; ty < tileRows; ty++) {
        for (int tx = 0; tx < tileCols; tx++) {
            if (tileMarks[(size_t)ty * (size_t)tileCols + (size_t)tx] == 0) {
                continue;
            }
            
            int left = tx * 64;
            int top = ty * 64;
            int width = (mod->width - left < 64) ? (mod->width - left) : 64;
            int height = (mod->height - top < 64) ? (mod->height - top) : 64;
            if (width <= 0 || height <= 0) {
                continue;
            }
            
            xstream_writeInt16(_drawCmd, (short)left);
            xstream_writeInt16(_drawCmd, (short)top);
            xstream_writeInt16(_drawCmd, (short)width);
            xstream_writeInt16(_drawCmd, (short)height);
        }
    }
    
    xstream_writeInt32(_drawCmd, 0);
    xstream_writeInt16(_drawCmd, mod->width);
    xstream_writeInt16(_drawCmd, mod->height);
    
    int dataLen = (int)((char*)_drawCmd->data_current - (char*)_drawCmd->data_start);
    *(int*)((char*)_drawCmd->data_start + sizeof(int)) = dataLen;
    
    // RFX progressive 데이타
    // 각 타일이 64x64 크기를 가져야 한다. (각 픽셀 YUVA)
    const int srcStride = mod->width * 4;
    const int dstStride = tileCols * 256;
    const int dstHeight = tileRows * 64;
    const size_t srcMinSize = (size_t)srcStride * (size_t)mod->height;
    const size_t dstSize = (size_t)dstStride * (size_t)dstHeight;
    
    if (imgDataSize < srcMinSize || dstSize == 0) {
        free(tileMarks);
        return;
    }
    
    void* mapped = mmap(NULL, dstSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (mapped == MAP_FAILED) {
        free(tileMarks);
        return;
    }
    
    memset(mapped, 0x00, dstSize);
    unsigned char* dst = (unsigned char*)mapped;
    const unsigned char* src = (const unsigned char*)imgData;
    
    for (int ty = 0; ty < tileRows; ty++) {
        for (int tx = 0; tx < tileCols; tx++) {
            if (tileMarks[(size_t)ty * (size_t)tileCols + (size_t)tx] == 0) {
                continue;
            }
            
            unsigned char* tileBase = dst + (((size_t)ty * (size_t)tileCols + (size_t)tx) * 64 * 64 * 4);
            unsigned char* yPlane = tileBase;
            unsigned char* uPlane = tileBase + 64 * 64;
            unsigned char* vPlane = tileBase + 2 * 64 * 64;
            unsigned char* aPlane = tileBase + 3 * 64 * 64;
            memset(aPlane, 0xFF, 64 * 64);
            
            const int left = tx * 64;
            const int top = ty * 64;
            for (int py = 0; py < 64; py++) {
                const int sy = top + py;
                for (int px = 0; px < 64; px++) {
                    const int sx = left + px;
                    const size_t p = (size_t)py * 64 + (size_t)px;
                    if (sx < mod->width && sy < mod->height) {
                        const size_t srcOffset = ((size_t)sy * (size_t)srcStride) + ((size_t)sx * 4);
                        unsigned char y;
                        unsigned char u;
                        unsigned char v;
                        bgra_to_yuv709(src[srcOffset], src[srcOffset + 1], src[srcOffset + 2],
                                       &y, &u, &v);
                        yPlane[p] = y;
                        uPlane[p] = u;
                        vPlane[p] = v;
                    }
                    else {
                        yPlane[p] = 0;
                        uPlane[p] = 128;
                        vPlane[p] = 128;
                    }
                }
            }
        }
    }
    
    XRDP_EGFX_START_FRAME startCmd;
    startCmd.header.cmdId = 11;
    startCmd.header.flags = 0;
    startCmd.header.pduLength = sizeof(startCmd);
    startCmd.timestamp = 0;
    startCmd.frame_id = frame_id;
    
    mod->server_egfx_cmd((struct mod*)mod, (char*)&startCmd, sizeof(startCmd), NULL, 0);
    mod->server_egfx_cmd((struct mod*)mod, (char*)_drawCmd->data_start, dataLen, (char*)mapped, (int)dstSize);
    free(tileMarks);
    
    XRDP_EGFX_END_FRAME endCmd;
    endCmd.header.cmdId = 12;
    endCmd.header.flags = 0;
    endCmd.header.pduLength = sizeof(endCmd);
    endCmd.frame_id = frame_id;
    
    mod->server_egfx_cmd((struct mod*)mod, (char*)&endCmd, sizeof(endCmd), NULL, 0);
}
