//
//  CursorHandler.cpp
//  OSXRDP
//
//  Created by byungho on 2/9/26.
//

#include "CursorHandler.h"
#include <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/time.h>

extern "C" {
    // private functions
    extern int CGSNewConnection(void* unused, int* newConnectionId);
    extern int CGSReleaseConnection(int connectionId);
    extern int CGSGetGlobalCursorDataSize(int connectionId, int* dataSize);
    extern int CGSGetGlobalCursorData(int connection, char *outData, int* ioDataSize, int* outRowBytes, CGRect* outRect, CGPoint* outHotspot, int* outDepth, int* outComponents, int* outBitsPerComponent);
    extern int CGSCurrentCursorSeed(void);
}

static inline int clamp_int(int v, int lo, int hi)
{
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

CursorHandler::CursorHandler() :
    _connectionId(0),
    _cursorseed(0),
    _lastCheckTime(0)
{
    CGSNewConnection(NULL, &_connectionId);
    _tmpbuffer = (char*)malloc(512 * 512 * 16);
}

CursorHandler::~CursorHandler()
{
    CGSReleaseConnection(_connectionId);

    if (_tmpbuffer) {
        free(_tmpbuffer);
        _tmpbuffer = NULL;
    }
}

void CursorHandler::HandleCursorInfo(cursor_data_t* cursor)
{
    // 커서가 이전과 달라졌거나, 프레임 드랍을 대비하여 마지막 커서 조회로부터 3초가 지났으면 커서 상태 조회
    int seed = CGSCurrentCursorSeed();
    long long now = GetCurrentTime();
    if (seed == _cursorseed && now - _lastCheckTime < 3000) {
        cursor->updated = 0;
        return;
    }
    _cursorseed = seed;
    _lastCheckTime = now;

    // 커서 데이터 크기 조회
    int datasize = 0;
    if (CGSGetGlobalCursorDataSize(_connectionId, &datasize) != 0) {
        cursor->updated = 0;
        return;
    }

    // 크기가 유효한지
    if (datasize <= 0 || datasize > (16 * 512 * 512)) {
        cursor->updated = 0;
        return;
    }

    int outRowBytes = 0;
    CGRect rect;
    CGPoint hotspot;
    int depth = 0;
    int comps = 0;
    int bpc = 0;

    // 커서 데이터 조회
    if (CGSGetGlobalCursorData(_connectionId,
                              _tmpbuffer,
                              &datasize,
                              &outRowBytes,
                              &rect,
                              &hotspot,
                              &depth,
                              &comps,
                              &bpc) != 0) {
        cursor->updated = 0;
        return;
    }

    int srcW = (int)lround(rect.size.width);
    int srcH = (int)lround(rect.size.height);

    if (srcW <= 0 || srcH <= 0) {
        cursor->updated = 0;
        return;
    }

    if (outRowBytes <= 0) {
        cursor->updated = 0;
        return;
    }

    if (outRowBytes < srcW * 4) {
        cursor->updated = 0;
        return;
    }

    if (datasize < outRowBytes * srcH) {
        cursor->updated = 0;
        return;
    }

    // macOS 용 ms windows app은 상관없지만, Windows 의 mstsc 는 정사각형 커서 모양만 받는것 같다.
    // 따라서 이를 정사각형 캔버스에 그리기위해 가장 가까운 크기를 조회한다.
    int dstSize = PickSquarePointerSize(srcW, srcH);
    if (dstSize > 96)
        dstSize = 96;

    if (dstSize * dstSize > MAX_CURSOR_IMG_BUFFER_SIZE) {
        cursor->updated = 0;
        return;
    }

    int hotX = (int)lround(hotspot.x);
    int hotY = (int)lround(hotspot.y);

    hotX = clamp_int(hotX, 0, dstSize - 1);
    hotY = clamp_int(hotY, 0, dstSize - 1);

    cursor->seed = seed;
    cursor->width = dstSize;
    cursor->height = dstSize;
    cursor->hotspotX = hotX;
    cursor->hotspotY = hotY;

    // 그리기 (정사각형)
    BuildSquarePointerBGRA(_tmpbuffer, outRowBytes, datasize, srcW, srcH, dstSize, cursor->cursorImgData);

    // 커서 이미지 크기
    cursor->cursorImgDataSize = cursor->width * cursor->height * 4;

    // 커서 이미지 mask
    //   (아직 미사용, BGRA 를 지원하지 않는 구형 클라이언트 용)
    ClearMask(cursor->cursorImgMask, cursor->width, cursor->height);
    cursor->cursorImgMaskSize = (cursor->width * cursor->height + 7) / 8;

    // osxup 에 커서 갱신이 필요하다고 전달
    cursor->updated = 1;
}

int CursorHandler::PickSquarePointerSize(int width, int height)
{
    int m = (width > height) ? width : height;

    if (m <= 32) return 32;
    if (m <= 48) return 48;
    if (m <= 64) return 64;
    return 96;
}

void CursorHandler::BuildSquarePointerBGRA(const char* src, int srcRowBytes, int srcSizeBytes, int srcWidth, int srcHeight, int dstSize, char* dstData)
{
    const int dstRowBytes = dstSize * 4;

    memset(dstData, 0, dstRowBytes * dstSize);

    int copyW = srcWidth;
    int copyH = srcHeight;

    if (copyW > dstSize) copyW = dstSize;
    if (copyH > dstSize) copyH = dstSize;

    if (srcRowBytes <= 0) return;
    if (srcSizeBytes < srcRowBytes * srcHeight) return;

    // rdp 의 커서는 상하를 반전해야 한다.
    for (int y = 0; y < copyH; ++y) {
        const uint8_t* srcRow = (const uint8_t*)src + y * srcRowBytes;
        uint8_t* dstRow = (uint8_t*)dstData + (dstSize - 1 - y) * dstRowBytes;
        memcpy(dstRow, srcRow, copyW * 4);
    }
}

void CursorHandler::ClearMask(char* mask, int width, int height)
{
    int maskBytes = (width * height + 7) / 8;
    maskBytes = clamp_int(maskBytes, 0, MAX_CURSOR_IMG_BUFFER_SIZE);
    memset(mask, 0x00, maskBytes);
}

long long CursorHandler::GetCurrentTime() {
    struct timeval te;
    gettimeofday(&te, NULL);
    return te.tv_sec * 1000LL + te.tv_usec / 1000;
}
