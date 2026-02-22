
#ifndef ConnectionManager_h
#define ConnectionManager_h

#include "../Paint/PaintManager.h"
#include "../Status/StatusManager.h"
#include "../Command/Command.h"

#include <pthread.h>

struct mod;

class ConnectionManager {
public:
    ConnectionManager();
    ~ConnectionManager();
    
    int Initialize();
    void Release();
    
    // 초기 연결 수행
    bool Connect(const struct mod* mod);
    
    // ipc 메시지 펌프 및 연결 상태 확인
    void KeepAlive();
    
    // 마우스 입력 전달
    void SendMouseInput(int inputType, short x, short y);
    
    // 키보드 입력 전달
    void SendKeyboardInput(int inputType, int keycode, int flags);
    
    // 상태 조회
    bool CanPaint();
    bool NeedTerminate();
    
    void Terminate();
    
    // 화면 그리기
    void Paint();
    void PaintEnd(int ackFrameId);
    
private:
    bool _inited;
    StatusManager _statusManager;
    Command _command;
    PaintManager _paintManager;
    
    xipc_t* _sessionIpc;
    xipc_t* _agentIpc;
    int _sessionId;
    const mod* _mod;
    
    bool _ConnectToSessionManager();
    bool _ConnectToAgent(int sessionId, bool isLockScreen);
    bool _PreparePaint();
        
    void _HandleSessionMessage(int sessionId, int isLockScreen);
        
    // session manager 수신 메시지 처리
    static int _OnReceivedSessionManagerMessage(xipc_t* t, xipc_t* client, void* data, int len);
    
    // agent 수신 메시지 처리
    static int _OnReceivedAgentManagerMessage(xipc_t* t, xipc_t* client, void* data, int len);
};

#endif /* ConnectionManager_h */
