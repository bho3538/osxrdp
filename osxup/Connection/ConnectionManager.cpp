#include "../pch.h"
#include "../osxup.h"
#include "ConnectionManager.h"
#include "osxrdp/packet.h"
#include "utils.h"

// session manager 서버 이름
static const char* OSXRDP_SESSIONMANAGER_NAME = "/tmp/osxrdpsessionmanager";
static const char* OSXRDP_AGENT_NAME = "/tmp/osxrdp";

static const int OSXRDP_RECONNECT_WAITCNT = 25;

namespace {
inline void AddWaitObject(void* read_objs, int* rcount, int fd) {
    if (read_objs == NULL || rcount == NULL || fd < 0) {
        return;
    }

    ((intptr_t*)read_objs)[*rcount] = (intptr_t)fd;
    (*rcount)++;
}
}

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
    _channelManager.Initialize(mod);
    
    _command.SendSessionRequestMsg(_sessionIpc, mod->username, (int)usernameLen);
    
    return true;
}

void ConnectionManager::Release() {
    if (_inited == false) return;
    
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
    
    _paintManager.Release();
    _channelManager.Release();
    
    _inited = false;
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
            
            // 세션 ipc 가 끊긴 경우 접속 종료 처리
            _statusManager.SetStopping();
            
            return;
        }
    }
    
    // 에이전트 연결이 끊긴 경우 (맨 처음 연결 init 제외)
    if (_agentIpc == NULL && _statusManager.CheckInitStatus() == false) {
        
        _sessionId = -1;
        
        // painter 와 커서 manager 는 재생성해야함 (agent 에 종속적)
        // 단, in-flight 프레임 ACK가 끝나기 전에는 공유메모리를 즉시 해제하지 않는다.
        if (_paintManager.TryReleaseForReconnect() == false) {
            return;
        }
        
        // 마지막 시도가 락스크린일 경우 재접속
        if (_statusManager.CheckReconnection() == false) {
            // 그렇지 않은 경우 종료
            _statusManager.SetStopping();
        }
        else {
            // 세션 재연결 시도를 위해 세션 정보 다시 조회
            _statusManager.SetRequestSession();
            _command.SendSessionRequestMsg(_sessionIpc, _mod->username, (int)strlen(_mod->username));
        }
    }
}

void ConnectionManager::GetWaitObjects(void* read_objs, int* rcount) {
    if (read_objs == NULL || rcount == NULL) {
        return;
    }

    if (_agentIpc != NULL) {
        AddWaitObject(read_objs, rcount, _agentIpc->fd);
        AddWaitObject(read_objs, rcount, _agentIpc->wakeup_pipe[0]);
    }

    if (_sessionIpc != NULL) {
        AddWaitObject(read_objs, rcount, _sessionIpc->fd);
        AddWaitObject(read_objs, rcount, _sessionIpc->wakeup_pipe[0]);
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

void ConnectionManager::SetSuppress(bool suppress) {
    _statusManager.SetSuppressed(suppress);
}

void ConnectionManager::Terminate() {
    _statusManager.SetStopping();
}

void ConnectionManager::Paint() {    
    _paintManager.Paint();
}

void ConnectionManager::PaintEnd(int ackFrameId) {
    _paintManager.PaintEnd(ackFrameId);
}

void ConnectionManager::HandleChannelMsg(long param1, long param2, long param3, long param4) {
    // extract channel data
    int channelId = (int)LOWORD(param1);
    int channelFlags = (int)HIWORD(param1);
    int dataLen = (int)param2;
    const char* data = (const char*)param3;
    int totalLen = (int)param4;
    
    // 유효한 (처리하는) 이벤트인지 확인
    int channel_msg_type = _channelManager.IsValidChannelMsg(channelId, channelFlags, data, dataLen, totalLen);
    if (channel_msg_type == OSXRDP_CHANNEL_INVALID) {
        return;
    }

    if (_agentIpc == NULL) {
        return;
    }
    
    // 아직은 클립보드만 처리 (agent 로 전달)
    if (channel_msg_type == OSXRDP_CHANNEL_CLIPBOARD) {
        _command.SendClipboardMsg(_agentIpc, channelId, channelFlags, data, dataLen, totalLen);
    }
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
    
    printf("Connect to agent %d %d\n", sessionId, isLockScreen);
    
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
    
    // 클립보드 활성화
    _channelManager.SendClipboardServerInit();
    
    _agentIpc = ipc;

    return true;
}

bool ConnectionManager::_PreparePaint() {
    
    bool inLockscreen = _statusManager.CheckInLockscreen();
    if (_paintManager.Initialize(_mod, PaintManager::CheckRecordFormat(_mod), _sessionId, inLockscreen) == false) {
        // log
        
        return false;
    }
    
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
                        
            _this->_HandleSessionMessage(sessionId, isLogined == 0 ? true : false);
        
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
                if (re != 1 || _this->_PreparePaint() == false) {
                    // log
                    _this->_statusManager.SetStopping();
                }
            }
            break;
        }
        case OSXRDP_CMDTYPE_CLIPBOARD: {
            int packetType = xstream_readInt32(stream);
            if (packetType == OSXRDP_PACKETTYPE_REP_SETCLIENTCLIP) {
                int channelFlags = xstream_readInt32(stream);
                int totalLen = xstream_readInt32(stream);
                int dataLen = xstream_readInt32(stream);
                const void* rawData = xstream_readData(stream, dataLen);

                if (rawData != NULL) {
                    _this->_channelManager.SendClipboardChannelData(rawData,
                                                                    dataLen,
                                                                    totalLen,
                                                                    channelFlags);
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
