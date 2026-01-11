
#ifndef ScreenRecorder_hpp
#define ScreenRecorder_hpp

#include "ipc.h"
#include "xstream.h"
#include "xshm.h"
#include "osxrdp/screenrecordshm.h"
#include "InputHandler.h"

class ScreenRecorder {
    
public:
    ScreenRecorder();
    ~ScreenRecorder();
        
    void HandleCommand(xipc_t* client, xstream_t* cmd);
    void Stop();
    void SendDisconnectMsgToClient();

private:
    void* _impl;
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
    
    static void HandleBGRA32RecordData(void* sampleBuffer, void* imgBuffer, void* userData);
    static void HandleBGRA32DirtyArea(void* sampleBuffer, void* imgBuffer, screenrecord_frame* current_frame, char* screenrecord_data);
    
    static void HandleNV12RecordData(void* sampleBuffer, void* imgBuffer, void* userData);
    static void HandleNV12DirtyArea(void* sampleBuffer, void* imgBuffer, screenrecord_frame* current_frame, char* screenrecord_data);
    
    static void HandleRecordCommand(int cmd, void* userData);
};

#endif /* ScreenRecorder_hpp */
