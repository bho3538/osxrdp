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
clamp_int(int value, int min_value, int max_value) {
    if (value < min_value) {
        return min_value;
    }
    
    if (value > max_value) {
        return max_value;
    }
    return value;
}

void PaintRFX::Initialize(const struct mod* mod) {
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
    */
    _width = mod->width;
    _height = mod->height;
    _tileCols = (_width + 63) / 64;
    _tileRows = (_height + 63) / 64;
    _tileTotal = _tileCols * _tileRows;
    _srcStride = _width * 3;
    _dstStride = _tileCols * 256;
    _dstHeight = _tileRows * 64;
    _srcMinSize = (size_t)_srcStride * (size_t)_height;
    _tileDataSize = (size_t)_dstStride * (size_t)_dstHeight;
    
    if (_tileCols <= 0 || _tileRows <= 0 || _tileTotal <= 0 || _tileDataSize == 0) {
        Release();
        return;
    }
    
    _drawCmd = xstream_create(512 * 1024 * 2);
    _tileMarks = (unsigned char*)malloc((size_t)_tileTotal);
    _tileIndices = (int*)malloc(sizeof(int) * (size_t)_tileTotal);
    _tileRects = (TileRect*)malloc(sizeof(TileRect) * (size_t)_tileTotal);
    
    if (_drawCmd == NULL || _tileMarks == NULL || _tileIndices == NULL || _tileRects == NULL) {
        Release();
        return;
    }
    
    // 64x64 단위의 타일 만들기
    for (int ty = 0; ty < _tileRows; ++ty) {
        for (int tx = 0; tx < _tileCols; ++tx) {
            const int idx = (ty * _tileCols) + tx;
            const int left = tx * 64;
            const int top = ty * 64;
            
            _tileRects[idx].left = (short)left;
            _tileRects[idx].top = (short)top;
            _tileRects[idx].width = (short)((_width - left < 64) ? (_width - left) : 64);
            _tileRects[idx].height = (short)((_height - top < 64) ? (_height - top) : 64);
        }
    }
}

void PaintRFX::Release() {
    if (_drawCmd != NULL) {
        xstream_free(_drawCmd);
        _drawCmd = NULL;
    }
    
    if (_tileMarks != NULL) {
        free(_tileMarks);
        _tileMarks = NULL;
    }
    
    if (_tileIndices != NULL) {
        free(_tileIndices);
        _tileIndices = NULL;
    }
    
    if (_tileRects != NULL) {
        free(_tileRects);
        _tileRects = NULL;
    }
    
    _width = 0;
    _height = 0;
    _tileCols = 0;
    _tileRows = 0;
    _tileTotal = 0;
    _srcStride = 0;
    _dstStride = 0;
    _dstHeight = 0;
    _srcMinSize = 0;
    _tileDataSize = 0;
}

void PaintRFX::DoPaint(const struct mod* mod, screenrecord_frame_t* frameInfo, char* imgData, size_t imgDataSize, int frame_id) {
    assert(mod != NULL);
    assert(frameInfo != NULL);
    assert(imgData != NULL);
    assert(_drawCmd != NULL);
    assert(_tileMarks != NULL);
    assert(_tileIndices != NULL);
    assert(_tileRects != NULL);

    if (mod->width != _width || mod->height != _height) {
        return;
    }

    xstream_resetPos(_drawCmd);

    // header
    xstream_writeInt16(_drawCmd, XR_RDPGFX_CMDID_WIRETOSURFACE_2);  // cmdId
    xstream_writeInt16(_drawCmd, 0);                                // flags
    xstream_writeInt32(_drawCmd, 0);                                // len

    // body
    xstream_writeInt16(_drawCmd, 0);                                // surface_id
    xstream_writeInt16(_drawCmd, XR_RDPGFX_CODECID_CAPROGRESSIVE);  // codec_id
    xstream_writeInt32(_drawCmd, 0);                                // codec_context_id
    xstream_writeInt8(_drawCmd,  XR_PIXEL_FORMAT_XRGB_8888);        // pixel_format
    xstream_writeInt32(_drawCmd, 0);                                // flags

    memset(_tileMarks, 0x00, (size_t)_tileTotal);

    int tileCount = 0;
    if (frameInfo->dirtyCount > 0 && frameInfo->dirtyCount < MAX_DIRTY_COUNT) {
        for (int i = 0; i < frameInfo->dirtyCount; i++) {
            int x0 = frameInfo->dirtys[i].x;
            int y0 = frameInfo->dirtys[i].y;
            int x1 = x0 + frameInfo->dirtys[i].width;
            int y1 = y0 + frameInfo->dirtys[i].height;

            x0 = clamp_int(x0, 0, _width);
            y0 = clamp_int(y0, 0, _height);
            x1 = clamp_int(x1, 0, _width);
            y1 = clamp_int(y1, 0, _height);
            if (x1 <= x0 || y1 <= y0) {
                continue;
            }

            int tx0 = x0 / 64;
            int ty0 = y0 / 64;
            int tx1 = (x1 - 1) / 64;
            int ty1 = (y1 - 1) / 64;
            for (int ty = ty0; ty <= ty1; ty++) {
                for (int tx = tx0; tx <= tx1; tx++) {
                    _tileMarks[(size_t)ty * (size_t)_tileCols + (size_t)tx] = 1;
                }
            }
        }

        for (int i = 0; i < _tileTotal; i++) {
            if (_tileMarks[(size_t)i] != 0) {
                _tileIndices[tileCount++] = i;
            }
        }
    }

    if (tileCount <= 0) {
        for (int i = 0; i < _tileTotal; i++) {
            _tileIndices[tileCount++] = i;
        }
    }

    // RFX progressive 처리를 위해 정렬된 (64) dirty area 를 설정
    xstream_writeInt16(_drawCmd, tileCount); // num_rects_d
    for (int i = 0; i < tileCount; ++i) {
        const TileRect* rect = &_tileRects[_tileIndices[i]];
        xstream_writeInt16(_drawCmd, rect->left);
        xstream_writeInt16(_drawCmd, rect->top);
        xstream_writeInt16(_drawCmd, rect->width);
        xstream_writeInt16(_drawCmd, rect->height);
    }

    xstream_writeInt16(_drawCmd, tileCount); // num_rects_c
    for (int i = 0; i < tileCount; ++i) {
        const TileRect* rect = &_tileRects[_tileIndices[i]];
        xstream_writeInt16(_drawCmd, rect->left);
        xstream_writeInt16(_drawCmd, rect->top);
        xstream_writeInt16(_drawCmd, rect->width);
        xstream_writeInt16(_drawCmd, rect->height);
    }

    xstream_writeInt32(_drawCmd, 0);
    xstream_writeInt16(_drawCmd, _width);
    xstream_writeInt16(_drawCmd, _height);

    int dataLen = (int)((char*)_drawCmd->data_current - (char*)_drawCmd->data_start);
    *(int*)((char*)_drawCmd->data_start + sizeof(int)) = dataLen;

    // SHM 검증: Process 1에서 만든 데이터가 타일 전체 크기와 일치하는지 확인
    if (imgDataSize < _tileDataSize || _tileDataSize == 0) {
        return;
    }

    // xrdp 내부에서 해제(munmap/free)할 목적지 버퍼 할당
    void* mapped = mmap(NULL, _tileDataSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (mapped == MAP_FAILED) {
        return;
    }

    unsigned char* dst = (unsigned char*)mapped;
    const unsigned char* src = (const unsigned char*)imgData; // 1:1 매핑된 SHM 데이터
    const size_t tileSize = 64 * 64 * 4; // 16KB (Y, U, V, A)

    // 🚀 압도적으로 단축된 메모리 복사 루프 (Zero-Copy 철학)
    for (int i = 0; i < tileCount; ++i) {
        const int tileIdx = _tileIndices[i];
        const size_t offset = (size_t)tileIdx * tileSize;
        
        // SHM에서 이미 완성된 16KB 타일을 그대로 덮어쓰기
        memcpy(dst + offset, src + offset, tileSize);
    }

    XRDP_EGFX_START_FRAME startCmd;
    startCmd.header.cmdId = 11;
    startCmd.header.flags = 0;
    startCmd.header.pduLength = sizeof(startCmd);
    startCmd.timestamp = 0;
    startCmd.frame_id = frame_id;

    mod->server_egfx_cmd((struct mod*)mod, (char*)&startCmd, sizeof(startCmd), NULL, 0);
    mod->server_egfx_cmd((struct mod*)mod, (char*)_drawCmd->data_start, dataLen, (char*)mapped, (int)_tileDataSize);

    XRDP_EGFX_END_FRAME endCmd;
    endCmd.header.cmdId = 12;
    endCmd.header.flags = 0;
    endCmd.header.pduLength = sizeof(endCmd);
    endCmd.frame_id = frame_id;

    mod->server_egfx_cmd((struct mod*)mod, (char*)&endCmd, sizeof(endCmd), NULL, 0);
}
