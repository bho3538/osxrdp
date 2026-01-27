#include "SessionManagerServer.h"
#import <Foundation/Foundation.h>

#include "xstream.h"
#include "osxrdp/packet.h"
#include "utils.h"
#include "sessionmanager.h"

SessionManagerServer::SessionManagerServer()
: _cmdPipe(NULL)
, _ioThreadStarted(0)
, _state(State_Idle) {
    pthread_mutex_init(&_stateLock, NULL);
}

SessionManagerServer::~SessionManagerServer() {
    Stop();
    pthread_mutex_destroy(&_stateLock);
}

void SessionManagerServer::Start() {
    // 서버가 시작중이거나 동작 중일 경우 무시
    if (IsState(State_Running) || IsState(State_Starting)) {
        return;
    }
    
    // 시작중으로 설정
    SetState(State_Starting);
    
    // ipc 서버 생성
    if (CreateCommandPipeServer() == false) {
        SetState(State_Idle);
        return;
    }

    // IO 스레드 시작
    if (StartIoThread() == false) {
        DestroyCommandPipeServer();
        SetState(State_Idle);
        return;
    }
    
    // Running으로 상태 변경
    SetState(State_Running);
}

void SessionManagerServer::Stop() {
    if (IsState(State_Idle) || IsState(State_Stopped)) {
        return;
    }
    
    if (IsState(State_Stopping)) {
        // 이미 정지 중이면 정지를 대기
        StopIoThread();
        return;
    }
    
    SetState(State_Stopping);
    
    // xipc_loop 탈출 유도
    SignalIoThreadToStop();
    
    // IO 스레드 종료 대기
    StopIoThread();
    
    // IPC 정리
    DestroyCommandPipeServer();
    
    // 상태 마무리
    SetState(State_Stopped);
}

bool SessionManagerServer::IsRunning() {
    return IsState(State_Running);
}

bool SessionManagerServer::CreateCommandPipeServer() {
    if (_cmdPipe != NULL) {
        NSLog(@"[SessionManagerServer]::CreateCommandPipeServer cmdPipe already exists.");
        return false;
    }
    
    xipc_t* cmdPipe = xipc_ctx_create(OnMessageReceived, this);
    if (cmdPipe == NULL) {
        NSLog(@"[SessionManagerServer]::CreateCommandPipeServer xipc_ctx_create failed.");
        return false;
    }
    
    if (xipc_create_server(cmdPipe, "/tmp/osxrdpsessionmanager", NULL, NULL) != 0) {
        xipc_destroy(cmdPipe);
        NSLog(@"[SessionManagerServer]::CreateCommandPipeServer xipc_create_server failed.");
        return false;
    }
    
    _cmdPipe = cmdPipe;
    return true;
}

void SessionManagerServer::DestroyCommandPipeServer() {
    if (_cmdPipe == NULL) {
        return;
    }
    
    xipc_destroy(_cmdPipe);
    _cmdPipe = NULL;
}

bool SessionManagerServer::StartIoThread() {
    if (_cmdPipe == NULL) {
        return false;
    }
    
    if (_ioThreadStarted) {
        return true;
    }
    
    // ipc 소켓을 기동하기 위한 thread 생성
    int rc = pthread_create(&_ioThread, NULL, &SessionManagerServer::IoThreadEntry, this);
    if (rc != 0) {
        NSLog(@"[SessionManagerServer]::StartIoThread pthread_create failed: %d", rc);
        _ioThreadStarted = 0;
        return false;
    }
    
    _ioThreadStarted = 1;
    return true;
}

void SessionManagerServer::StopIoThread() {
    if (_ioThreadStarted) {
        xipc_end_loop(_cmdPipe);
        
        pthread_join(_ioThread, NULL);
        _ioThreadStarted = 0;
    }
}

void SessionManagerServer::SignalIoThreadToStop() {
    if (_cmdPipe == NULL) {
        return;
    }
    
    xipc_end_loop(_cmdPipe);
}

void* SessionManagerServer::IoThreadEntry(void* arg) {
    SessionManagerServer* _this = (SessionManagerServer*)arg;
    if (_this == NULL || _this->_cmdPipe == NULL) {
        return NULL;
    }
    
    xipc_loop(_this->_cmdPipe);
    return NULL;
}

int SessionManagerServer::OnMessageReceived(xipc_t* t, xipc_t* client, void* data, int len) {
    if (t == NULL || data == NULL || len <= 0) {
        return 0;
    }
    
    if (client == NULL) {
        return 0;
    }
        
    xstream_t* cmd = xstream_create_for_read(data, len);
    if (cmd == NULL) {
        return 0;
    }
    
    SessionManagerServer* _this = (SessionManagerServer*)t->user_data;
    if (_this == NULL) {
        xstream_free(cmd);
        return 0;
    }
    
    // Stopping/Stopped 상태에서는 명령 무시
    bool canHandle = _this->IsState(State_Running);
    if (!canHandle) {
        xstream_free(cmd);
        return 0;
    }
    
    int cmdType = xstream_readInt32(cmd);
    switch (cmdType) {
        case OSXRDP_SESSMAN_REQUEST_SESSION: {
            session_info_t sessionInfo = {0,};
            
            const char* username = xstream_readStr(cmd, NULL);
            if (osxrdp_sessionmanager_getsessioninfo(username, &sessionInfo) != 0) {
                // 접속하려는 사용자의 세션이 없음
                // 세션을 만들고 정보를 osxup 로 전달
                if (osxrdp_sessionmanager_createsession(&sessionInfo) != 0) {
                    // 세션을 못만듬
                    sessionInfo.sessionId = -1;
                }
            }
            
            // 정보를 다시 osxup 로 전달
            xstream* result = xstream_create(32);
            if (result != NULL) {
                xstream_writeInt32(result, OSXRDP_SESSMAN_REPLY_SESSION);
                xstream_writeInt32(result, sessionInfo.sessionId);
                xstream_writeInt32(result, sessionInfo.isLogined);
                
                int rawBufferLen = 0;
                const void* rawBuffer = xstream_get_raw_buffer(result, &rawBufferLen);
                
                xipc_send_data(client, rawBuffer, rawBufferLen);
                
                xstream_free(result);
            }
            
            break;
        }
        case OSXRDP_SESSMAN_REQUEST_RELEASESESSION: {
            int sessionId = xstream_readInt32(cmd);
            
            osxrdp_sessionmanager_releasesession(sessionId);
            
            break;
        }
        default:
            break;
    }
    
    xstream_free(cmd);
    return 0;
}

// 상태 접근 헬퍼
void SessionManagerServer::SetState(State s) {
    pthread_mutex_lock(&_stateLock);
    _state = s;
    pthread_mutex_unlock(&_stateLock);
}

SessionManagerServer::State SessionManagerServer::GetState() {
    pthread_mutex_lock(&_stateLock);
    State s = _state;
    pthread_mutex_unlock(&_stateLock);
    return s;
}

bool SessionManagerServer::IsState(State s) {
    pthread_mutex_lock(&_stateLock);
    bool same = (_state == s);
    pthread_mutex_unlock(&_stateLock);
    return same;
}
