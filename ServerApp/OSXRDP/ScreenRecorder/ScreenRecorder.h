
#ifndef ScreenRecorder_hpp
#define ScreenRecorder_hpp

#include "ipc.h"
#include "xstream.h"
#include "xshm.h"
#include "osxrdp/screenrecordshm.h"
#include "InputHandler.h"

class ScreenRecorder {
    
public:
    ScreenRecorder(bool useLegacyRecorder);
    ~ScreenRecorder();
        
    void HandleCommand(xipc_t* client, xstream_t* cmd);
    void Stop();
    void SendDisconnectMsgToClient();

private:
    void* _impl;
    void* _implFallback;
    void* _encodingSession;
    xshm_t* _recordShm;
    xipc_t* _client;
    int _gfxFlags;
    
    // Input handler (mouse, keyboard)
    InputHandler* _inputHandler;
    
    bool CreateRecordShm(int width, int height, int framerate);
    void DestroyRecordShm();
    
    bool StartRecord(xstream_t* cmd);
    
    static void* GetDisplay(int monitorIndex);
    
    // 녹화 데이터 처리기
    static void HandleBGRA32RecordData(void* sampleBuffer, void* imgBuffer, void* userData);
    static void HandleBGRA32DirtyArea(void* sampleBuffer, void* imgBuffer, screenrecord_frame* current_frame, char* screenrecord_data);
    
    static void HandleNV12RecordData(void* sampleBuffer, void* imgBuffer, void* userData);
    static void HandleNV12DirtyArea(void* sampleBuffer, void* imgBuffer, screenrecord_frame* current_frame, char* screenrecord_data);
    
    static void HandleFallbackBGRA32RecordData(void* pixelBuffer, const CGRect* dirtyRects, int dirtyRectsCnt, void* userData);
    static void HandleFallbackBGRA32DirtyArea(void* pixelBuffer, screenrecord_frame* current_frame, const CGRect* dirtyRects, int dirtyRectsCnt, char* screenrecord_data);
    
    static void HandleFallbackNV12RecordData(void* pixelBuffer, const CGRect* dirtyRects, int dirtyRectsCnt, void* userData);
    static void HandleFallbackNV12DirtyArea(void* pixelBuffer, screenrecord_frame* current_frame, const CGRect* dirtyRects, int dirtyRectsCnt, char* screenrecord_data);
    
    static void ProcessDirtyArea(CGRect* rect, int limitX, int limitY);
    
    
    static void HandleRecordCommand(int cmd, void* userData);
};

#endif /* ScreenRecorder_hpp */
