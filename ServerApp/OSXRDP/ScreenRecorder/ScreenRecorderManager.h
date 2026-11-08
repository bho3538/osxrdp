
#ifndef ScreenRecorder_hpp
#define ScreenRecorder_hpp

#include <Accelerate/Accelerate.h>

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
        int monitorCount;
        
        struct MONITOR_INFO {
            int left;
            int top;
            int right;
            int bottom;
            int is_primary;
            int displayId;
            int outputIndex;
            int refresh_rate;
        } monitorInfo[16];
    };
    
    struct RecordStartParams _recordParams;

    void* _recorder[16];
    int _recorderCnt;
    
    bool _useLegacyRecorder;
    
    // 녹화 데이터가 저장되는 공유 메모리
    xshm_t* _recordShm[16];
    int _recordShmCnt;
    
    // 마우스 커서 이미지가 저장되는 공유 메모리
    xshm_t* _cursorShm;

    // osxup 에게 shm fd 를 보낸 소켓
    // osxup 이 accept 시 LOCAL_PEERPID 로 송신자를 검증하므로, 녹화 종료 전까지 닫지 않는다.
    xipc_t* _shmFdIpc;

    // osxup 로 명령을 보내기 위한 파이프
    xipc_t* _client;
    
    // Input handler (mouse, keyboard)
    InputHandler _inputHandler;
    
    // Mouse cursor handler
    CursorHandler _cursorHandler;
    
    VirtualMonitor _virtualMonitor;

    vImage_ARGBToYpCbCr _rfxConversionInfo;

    screenrecord_frame_t _pendingDirty[16];
    bool _pendingDirtyFull[16];

    bool CreateRecordShm(int recordIdx);
    void DestroyRecordShm();
    
    bool CreateCursorShm();
    void DestroyCursorShm();
    
    // osxup 에게 공유 메모리 fd 전달
    bool SendShmFds(xipc_t* client);
    
    bool StartRecord(xstream_t* cmd);
    bool InitRFXConversion();
    
    bool ParseStartRecordParams(xstream_t* cmd, RecordStartParams* params);
    bool PrepareRecordResources();
    
    // 녹화기 설정
    bool ResolveDisplayForRecorder();
    int GetMonitorRecordWidth(int recordIdx);
    int GetMonitorRecordHeight(int recordIdx);

    // 녹화 데이터 처리기
    static void HandleBGRA32RecordData(void* pixelBuffer, const CGRect* dirtyRects, int dirtyRectsCnt, void* userData, int displayIdx);
    static void HandleBGRA32DirtyArea(void* pixelBuffer, screenrecord_frame* current_frame, const CGRect* dirtyRects, int dirtyRectsCnt, char* screenrecord_data);
    
    static void HandleNV12PackedRecordData(void* pixelBuffer, const CGRect* dirtyRects, int dirtyRectsCnt, void* userData, int displayIdx);
    static void HandleNV12PackedDirtyArea(void* pixelBuffer, screenrecord_frame* current_frame, const CGRect* dirtyRects, int dirtyRectsCnt, char* screenrecord_data);
    
    static void HandleNV12AlignedRecordData(void* pixelBuffer, const CGRect* dirtyRects, int dirtyRectsCnt, void* userData, int displayIdx);
    static void HandleNV12AlignedDirtyArea(void* pixelBuffer, screenrecord_frame* current_frame, const CGRect* dirtyRects, int dirtyRectsCnt, char* screenrecord_data);
    
    static void HandleRFXRecordData(void* pixelBuffer, const CGRect* dirtyRects, int dirtyRectsCnt, void* userData, int displayIdx);
    bool HandleRFXDirtyArea(void* pixelBuffer, screenrecord_frame* current_frame, const CGRect* dirtyRects, int dirtyRectsCnt, char* screenrecord_data);
    
    // 데이터를 작성할 slot 찾기
    bool AcquireFrameSlot(screenrecord_shm_t** recordInfoOut, screenrecord_frame** frameOut, char** dataOut, unsigned int* writePosOut, int displayIdx);
    
    // 데이터 작성 완료 flag 설정
    void CommitFrameSlot(screenrecord_shm_t* recordInfo, unsigned int writePos, int displayIdx);

    // osxup 에게 그릴 데이터가 있음을 알림 (NEEDPAINT)
    void SendNeedPaintMsg(int displayIdx);

    // NV12Packed 데이터를 메모리에 기록
    static bool CopyNV12PackedFrame(void* imageBuffer, char* screenrecord_data, int* widthOut, int* heightOut);
    
    // NV12Aligned 데이터를 메모리에 기록
    static bool CopyNV12AlignedFrame(void* imageBuffer, char* screenrecord_data, int* widthOut, int* heightOut);
    
    // BGRA32 데이터를 메모리에 기록
    static bool CopyBGRA32Frame(void* imageBuffer, char* screenrecord_data, int* widthOut, int* heightOut);

    // YUV444 데이터를 메모리에 기록
    bool CopyRFXFrame(void* imageBuffer, char* screenrecord_data, int* widthOut, int* heightOut);
    
    // dirty area (변화한 구역) 정보 처리
    inline static void ProcessDirtyArea(const CGRect* rect, int limitX, int limitY, struct RECT* dst);
    
    void ResetPendingDirty();
    void ResetPendingDirty(int displayIdx);
    void AddPendingDirty(int displayIdx, const CGRect* dirtyRects, int dirtyRectsCnt, int width, int height);
    void AddPendingDirtyFromPixelBuffer(int displayIdx, void* pixelBuffer, const CGRect* dirtyRects, int dirtyRectsCnt);
    void ApplyPendingDirty(int displayIdx, screenrecord_frame* current_frame);
    
    static void PopulateDirtyRectsFromSampleBuffer(void* sampleBuffer, int width, int height, screenrecord_frame* current_frame);
    static void PopulateDirtyRectsFromArray(const CGRect* dirtyRects, int dirtyRectsCnt, int width, int height, screenrecord_frame* current_frame);
    
    static void HandleRecordCommand(int cmd, void* userData);
};

#endif /* ScreenRecorder_hpp */
