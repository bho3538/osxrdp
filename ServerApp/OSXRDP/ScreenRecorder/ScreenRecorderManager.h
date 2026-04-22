
#ifndef ScreenRecorder_hpp
#define ScreenRecorder_hpp

#include "ipc.h"
#include "xstream.h"
#include "xshm.h"
#include "osxrdp/screenrecordshm.h"
#include "InputHandler.h"
#include "CursorHandler.h"
#include "../VirtualMon/VirtualMonitor.h"

class ScreenRecorderManager {
    
public:
    ScreenRecorderManager(bool useLegacyRecorder);
    ~ScreenRecorderManager();
        
    void HandleCommand(xipc_t* client, xstream_t* cmd);
    void Stop();
    void SendDisconnectMsgToClient();

private:
    // 녹화 요청 파라미터
    struct RecordStartParams {
        int monitorIndex;
        int width;
        int height;
        int framerate;
        int recordFormat;
        int useVirtualMon;
    };

    // ScreenRecorderImpl
    void* _impl;
    
    // 녹화 데이터가 저장되는 공유 메모리
    xshm_t* _recordShm;
    
    // 마우스 커서 이미지가 저장되는 공유 메모리
    xshm_t* _cursorShm;
    
    // osxup 로 명령을 보내기 위한 파이프
    xipc_t* _client;
    
    // Input handler (mouse, keyboard)
    InputHandler _inputHandler;
    
    // Mouse cursor handler
    CursorHandler _cursorHandler;
    
    VirtualMonitor _virtualMonitor;
    
    bool CreateRecordShm(int width, int height, int framerate);
    void DestroyRecordShm();
    
    bool CreateCursorShm();
    void DestroyCursorShm();
    
    bool StartRecord(xstream_t* cmd);
    
    bool ParseStartRecordParams(xstream_t* cmd, RecordStartParams* params);
    bool PrepareRecordResources(const RecordStartParams* params);
    
    // 녹화에 사용할 디스플레이 조회
    bool ResolveDisplayForRecorder(const RecordStartParams* params, int* displayIdOut);

    // 녹화 데이터 처리기
    static void HandleBGRA32RecordData(void* pixelBuffer, const CGRect* dirtyRects, int dirtyRectsCnt, void* userData);
    static void HandleBGRA32DirtyArea(void* pixelBuffer, screenrecord_frame* current_frame, const CGRect* dirtyRects, int dirtyRectsCnt, char* screenrecord_data);
    
    static void HandleNV12PackedRecordData(void* pixelBuffer, const CGRect* dirtyRects, int dirtyRectsCnt, void* userData);
    static void HandleNV12PackedDirtyArea(void* pixelBuffer, screenrecord_frame* current_frame, const CGRect* dirtyRects, int dirtyRectsCnt, char* screenrecord_data);
    
    static void HandleNV12AlignedRecordData(void* pixelBuffer, const CGRect* dirtyRects, int dirtyRectsCnt, void* userData);
    static void HandleNV12AlignedDirtyArea(void* pixelBuffer, screenrecord_frame* current_frame, const CGRect* dirtyRects, int dirtyRectsCnt, char* screenrecord_data);
    
    static void HandleRFXRecordData(void* pixelBuffer, const CGRect* dirtyRects, int dirtyRectsCnt, void* userData);
    static void HandleRFXDirtyArea(void* pixelBuffer, screenrecord_frame* current_frame, const CGRect* dirtyRects, int dirtyRectsCnt, char* screenrecord_data);
    
    // 데이터를 작성할 slot 찾기
    bool AcquireFrameSlot(screenrecord_shm_t** recordInfoOut, screenrecord_frame** frameOut, char** dataOut, unsigned int* writePosOut);
    
    // 데이터 작성 완료 flag 설정
    void CommitFrameSlot(screenrecord_shm_t* recordInfo, unsigned int writePos);

    // NV12Packed 데이터를 메모리에 기록
    static bool CopyNV12PackedFrame(void* imageBuffer, char* screenrecord_data, int* widthOut, int* heightOut);
    
    // NV12Aligned 데이터를 메모리에 기록
    static bool CopyNV12AlignedFrame(void* imageBuffer, char* screenrecord_data, int* widthOut, int* heightOut);
    
    // YUV444 데이터를 메모리에 기록
    static bool CopyYUV444Frame(void* imageBuffer, char* screenrecord_data, int* widthOut, int* heightOut);
    
    // BGRA32 데이터를 메모리에 기록
    static bool CopyBGRA32Frame(void* imageBuffer, char* screenrecord_data, int* widthOut, int* heightOut);
    
    // dirty area (변화한 구역) 정보 처리
    inline static void ProcessDirtyArea(const CGRect* rect, int limitX, int limitY, struct RECT* dst);
    
    static void PopulateDirtyRectsFromSampleBuffer(void* sampleBuffer, int width, int height, screenrecord_frame* current_frame);
    static void PopulateDirtyRectsFromArray(const CGRect* dirtyRects, int dirtyRectsCnt, int width, int height, screenrecord_frame* current_frame);
    
    static void HandleRecordCommand(int cmd, void* userData);
};

#endif /* ScreenRecorder_hpp */
