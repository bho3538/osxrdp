//
//  CursorHandler.h
//  OSXRDP
//
//  Created by byungho on 2/9/26.
//

#ifndef CursorHandler_h
#define CursorHandler_h

#include "osxrdp/screenrecordshm.h"

class CursorHandler {
public:
    CursorHandler();
    ~CursorHandler();
    
    bool HandleCursorInfo(cursor_data_t* cursor);
    
private:
    int _cursorseed;
    
    char* _tmpbuffer;
    
    // 마우스 커서 정보를 가져오기 위한 connection id
    int _connectionId;
    
    long long _lastCheckTime;
    
    static int PickSquarePointerSize(int width, int height);
    static void BuildSquarePointerBGRA(const char* src, int srcRowBytes, int srcSizeBytes, int srcWidth, int srcHeight, int dstSize, char* dstData);
};

#endif /* CursorHandler_h */
