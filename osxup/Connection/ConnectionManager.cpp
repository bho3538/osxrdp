#include "../pch.h"
#include "../osxup.h"
#include "ConnectionManager.h"
#include "osxrdp/packet.h"
#include "utils.h"

// session manager 서버 이름
static const char* OSXRDP_SESSIONMANAGER_NAME = "/tmp/osxrdpsessionmanager";
static const char* OSXRDP_AGENT_NAME = "/tmp/osxrdp";

static const int OSXRDP_RECONNECT_WAITCNT = 25;

ConnectionManager::ConnectionManager() :
    _inited(false),
    _sessionIpc(NULL),
    _agentIpc(NULL),
    _sessionId(0),
    _mod(NULL)
{}

ConnectionManager::~ConnectionManager() {}

int ConnectionManager::Initialize() {
    assert(_inited == false);
    assert(_agentIpc == NULL);
    assert(_sessionIpc == NULL);
    
    // 처음에는 무조건 세션 메니저에 연결
    if (_ConnectToSessionManager() == false) {
        // log
        return -1;
    }
    
    _inited = true;
    
    // log
    
    return 0;
}

bool ConnectionManager::Connect(const mod* mod) {
    assert(mod != NULL);
    
    if (mod == NULL) {
        // log
        return false;
    }
    
    if (PaintManager::CheckRecordFormat(mod) == -1) {
        // log
        return false;
    }
    
    size_t usernameLen = strlen(mod->username);
    if (usernameLen == 0 || usernameLen > 260) {
        // log
        return false;
    }
    
    _mod = mod;
    
    _command.SendSessionRequestMsg(_sessionIpc, mod->username, (int)usernameLen);
    
    return true;
}

void ConnectionManager::Release() {
    assert(_inited == true);
    
    _paintManager.Release();
    
    // close all ipc
    if (_agentIpc != NULL) {
        xipc_loop_once(_agentIpc);
        xipc_destroy(_agentIpc);
        _agentIpc = NULL;
    }
    
    if (_sessionIpc != NULL) {
        xipc_loop_once(_sessionIpc);
        xipc_destroy(_sessionIpc);
        _sessionIpc = NULL;
    }
    
    if (_inited == false) {
        return;
    }
}

void ConnectionManager::KeepAlive() {
    // agent ipc 와 연결된 경우
    if (_agentIpc != NULL) {
        // 쌓인 메시지를 처리
        xipc_loop_once(_agentIpc);

        // 연결이 끊긴 경우
        if (_agentIpc->closed == 1) {
            // 파괴
            xipc_destroy(_agentIpc);
            _agentIpc = NULL;
        }
    }
    
    // 세션 ipc 와 연결된 경우
    if (_sessionIpc != NULL) {
        // 쌓인 메시지를 처리
        xipc_loop_once(_sessionIpc);
        
        if (_sessionIpc->closed == 1) {
            // 파괴
            xipc_destroy(_sessionIpc);
            _sessionIpc = NULL;
        }
    }
    
    // 에이전트 연결이 끊긴 경우 (맨 처음 연결 init 제외)
    if (_agentIpc == NULL && _statusManager.CheckInitStatus() == false) {
        
        // painter 와 커서 manager 는 재생성해야함 (agent 에 종속적)
        _paintManager.Release();
        
        // 마지막 시도가 락스크린일 경우 재접속
        if (_statusManager.CheckReconnection() == false || _ConnectToAgent(_sessionId, 0) == false) {
            // 그렇지 않은 경우 종료
            _statusManager.SetStopping();
        }
    }
}

void ConnectionManager::SendMouseInput(int inputType, short x, short y) {
    assert(_agentIpc != NULL);
    
    _command.SendMouseInputMsg(_agentIpc, inputType, x, y);
}

void ConnectionManager::SendKeyboardInput(int inputType, int keycode, int flags) {
    assert(_agentIpc != NULL);

    _command.SendKeyboardInputMsg(_agentIpc, inputType, keycode, flags);
}

bool ConnectionManager::CanPaint() {
    return _statusManager.CheckCanPaint();
}

bool ConnectionManager::NeedTerminate() {
    return _statusManager.CheckNeedTerminate();
}

void ConnectionManager::Paint() {    
    _paintManager.Paint();
}

bool ConnectionManager::_ConnectToSessionManager() {
    xipc_t* ipc = xipc_ctx_create(_OnReceivedSessionManagerMessage, this);
    if (ipc == NULL) {
        return false;
    }
    
    if (xipc_connect_server(ipc, OSXRDP_SESSIONMANAGER_NAME) != 0) {
        xipc_destroy(ipc);
        
        return false;
    }
    
    // 상태 변경
    _statusManager.SetRequestSession();
    
    _sessionIpc = ipc;
    
    return true;
}

bool ConnectionManager::_ConnectToAgent(int sessionId, bool isLockScreen) {
    assert(sessionId > 0);
    
    // 상태 변경
    _statusManager.SetAgentConnecting(isLockScreen);
    
    // session id 저장
    _sessionId = sessionId;
    
    // agent 에 접속
    xipc_t* ipc = xipc_ctx_create(_OnReceivedAgentManagerMessage, this);
    if (ipc == NULL) {
        // log
        return false;
    }
    
    // 상태에 맞는 agent 주소 찾기
    char server_name[512] = {0,};
    if (get_object_name(sessionId, OSXRDP_AGENT_NAME, server_name, sizeof(server_name), isLockScreen) == 0) {
        // log
        return false;
    }
    
    // agent 에 연결
    // agent 가 늦게 뜰 수 있으므로 여러번 시도 (timeout을 둔다)
    bool connected = false;
    for (int i = 0; i < OSXRDP_RECONNECT_WAITCNT; i++) {
        if (xipc_connect_server(ipc, server_name) == 0) {
            connected = true;
            break;
        }
        
        // 연결 시도 중 종료 요청이 이미 온 경우 (가능한가?)
        if (_statusManager.CheckNeedTerminate()) {
            connected = false;
            break;
        }
      
        sleep(1);
    }
    
    if (connected == false) {
        xipc_destroy(ipc);
        
        return false;
    }
    
    // 접속 완료 상태 갱신
    _statusManager.SetAgentConnected(isLockScreen);
    
    // 화면 녹화 데이터 요청
    _command.SendRecordStartMsg(ipc, _mod->width, _mod->height, PaintManager::CheckRecordFormat(_mod), _mod->usevirtualmon);
    
    _agentIpc = ipc;

    return true;
}

bool ConnectionManager::_PreparePaint() {
    
    bool inLockscreen = _statusManager.CheckInLockscreen();
    if (_paintManager.Initialize(_mod, PaintManager::CheckRecordFormat(_mod), _sessionId, inLockscreen) == false) {
        // log
        
        return false;
    }
    
    // cursor manager
    
    
    _statusManager.SetAgentRecordStart(inLockscreen);
    
    return true;
}

void ConnectionManager::_HandleSessionMessage(int sessionId, int isLockScreen) {
    if (sessionId <= 0) {
        // log
        _statusManager.SetStopping();
        return;
    }
    
    if (_ConnectToAgent(sessionId, isLockScreen) == false) {
        // log
        _statusManager.SetStopping();
        return;
    }
}

int ConnectionManager::_OnReceivedSessionManagerMessage(xipc_t* t, xipc_t* client, void* data, int len) {
    assert(t != NULL);
    assert(data != NULL);
    assert(len > 0);
    
    if (t == NULL) {
        return -1;
    }
    
    if (data == NULL || len <= 0) {
        return -1;
    }
    
    ConnectionManager* _this = (ConnectionManager*)t->user_data;
    
    xstream_t* stream = xstream_create_for_read(data, len);
    int cmdType = xstream_readInt32(stream);
    
    switch (cmdType) {
        case OSXRDP_SESSMAN_REPLY_SESSION: {
            int sessionId = xstream_readInt32(stream);
            int isLogined = xstream_readInt32(stream);
            
            _this->_HandleSessionMessage(sessionId, !isLogined);
        
            break;
        }
        default:
            break;
    }

    xstream_free(stream);
    
    return 0;
}

int ConnectionManager::_OnReceivedAgentManagerMessage(xipc_t* t, xipc_t* client, void* data, int len) {
    assert(t != NULL);
    assert(data != NULL);
    assert(len > 0);
    
    if (t == NULL) {
        return -1;
    }
    
    if (data == NULL || len <= 0) {
        return -1;
    }
    
    ConnectionManager* _this = (ConnectionManager*)t->user_data;
    
    xstream_t* stream = xstream_create_for_read(data, len);
    int cmdType = xstream_readInt32(stream);
    
    switch (cmdType) {
        case OSXRDP_CMDTYPE_SCREEN: {
            int packetType = xstream_readInt32(stream);
            if (packetType == OSXRDP_PACKETTYPE_REP_SCREEN) {
                int re = xstream_readInt32(stream);
                if (re == 1) {
                    _this->_PreparePaint();
                }
                else {
                    // log
                    _this->_statusManager.SetStopping();
                }
            }
            break;
        }
        case OSXRDP_CMDTYPE_MSGFROMAGENT: {
            int packetType = xstream_readInt32(stream);
            if (packetType == OSXRDP_PACKETTYPE_TERMINATE) {
                // log
                _this->_statusManager.SetStopping();
            }
            break;
        }
        default:
            break;
    }
    
    xstream_free(stream);
    return 0;
}
