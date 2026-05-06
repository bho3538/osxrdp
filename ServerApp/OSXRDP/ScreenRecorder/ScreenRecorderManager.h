
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
        int monitorCount;
        
        struct MONITOR_INFO {
            int left;
            int top;
            int right;
            int bottom;
            int is_primary;
            int displayId;
            int outputIndex;
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
    
    // osxup 로 명령을 보내기 위한 파이프
    xipc_t* _client;
    
    // Input handler (mouse, keyboard)
    InputHandler _inputHandler;
    
    // Mouse cursor handler
    CursorHandler _cursorHandler;
    
    VirtualMonitor _virtualMonitor;

    // RFX YUV444 canonical buffer — dirty 영역만 변환해 누적한 뒤, 해당 타일만 SHM slot 에
    // 포장(indices + tileData)해 내보낸다.
    uint8_t* _rfxCanonical;
    size_t   _rfxCanonicalSize;
    int      _rfxCanonicalWidth;
    int      _rfxCanonicalHeight;
    size_t   _rfxTileCols;
    size_t   _rfxTileRows;
    
    // 다음 프레임을 full redraw 로 내보내야 하는지 표시.
    bool     _rfxFullRedrawRequired;

    bool CreateRecordShm(int recordIdx);
    void DestroyRecordShm();
    
    bool CreateCursorShm();
    void DestroyCursorShm();
    
    bool StartRecord(xstream_t* cmd);
    
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

    // NV12Packed 데이터를 메모리에 기록
    static bool CopyNV12PackedFrame(void* imageBuffer, char* screenrecord_data, int* widthOut, int* heightOut);
    
    // NV12Aligned 데이터를 메모리에 기록
    static bool CopyNV12AlignedFrame(void* imageBuffer, char* screenrecord_data, int* widthOut, int* heightOut);
    
    // BGRA32 데이터를 메모리에 기록
    static bool CopyBGRA32Frame(void* imageBuffer, char* screenrecord_data, int* widthOut, int* heightOut);

    // RFX canonical buffer 관리 및 BGRA -> YUV444 타일 변환 (dirty 영역만)
    bool EnsureRFXCanonical(int width, int height);
    // 다음 프레임을 full redraw 로 돌리도록 플래그 설정
    void InvalidateRFXCanonical();
    void ReleaseRFXCanonical();
    bool ConvertRFXTile(const uint8_t* bgraBase, size_t bgraStride, int width, int height, int tileCol, int tileRow, uint8_t* tileBase);
    
    // dirty area (변화한 구역) 정보 처리
    inline static void ProcessDirtyArea(const CGRect* rect, int limitX, int limitY, struct RECT* dst);
    
    static void PopulateDirtyRectsFromSampleBuffer(void* sampleBuffer, int width, int height, screenrecord_frame* current_frame);
    static void PopulateDirtyRectsFromArray(const CGRect* dirtyRects, int dirtyRectsCnt, int width, int height, screenrecord_frame* current_frame);
    
    static void HandleRecordCommand(int cmd, void* userData);
};

#endif /* ScreenRecorder_hpp */
