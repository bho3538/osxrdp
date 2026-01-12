#include "MirrorAppServer.h"
#include "xstream.h"
#import <Foundation/Foundation.h>
#include <unistd.h>
#include <string.h>
#include "../Utils/PermissionCheckUtils.h"
#include "osxrdp/packet.h"
#include "utils.h"

MirrorAppServer::MirrorAppServer()
: _cmdPipe(NULL)
, _ioThreadStarted(0)
, _state(State_Idle)
, _client(NULL) {
    pthread_mutex_init(&_stateLock, NULL);
}

MirrorAppServer::~MirrorAppServer() {
    Stop();
    pthread_mutex_destroy(&_stateLock);
}

void MirrorAppServer::Start() {
    // 서버가 시작중이거나 동작 중일 경우 무시
    if (IsState(State_Running) || IsState(State_Starting)) {
        return;
    }
    
    // 필수 권한이 있는지 확인
    if (PermissionCheckUtils::HasAllPermissionToStartRemoteConnection() == false) {
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

void MirrorAppServer::Stop() {
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

bool MirrorAppServer::IsRunning() {
    return IsState(State_Running);
}

bool MirrorAppServer::CreateCommandPipeServer() {
    if (_cmdPipe != NULL) {
        NSLog(@"[MirrorAppServer]::CreateCommandPipeServer cmdPipe already exists.");
        return false;
    }
    
    xipc_t* cmdPipe = xipc_ctx_create(OnMessageReceived, this);
    if (cmdPipe == NULL) {
        NSLog(@"[MirrorAppServer]::CreateCommandPipeServer xipc_ctx_create failed.");
        return false;
    }
    
    char server_path[512];
    if (get_object_name_by_username("/tmp/osxrdp", server_path, 512) == 0) {
        NSLog(@"[MirrorAppServer]::CreateCommandPipeServer get_object_name_by_username failed.");
        return false;
    }
    
    if (xipc_create_server(cmdPipe, server_path, OnClientConnected, OnClientDisconnected) != 0) {
        xipc_destroy(cmdPipe);
        NSLog(@"[MirrorAppServer]::CreateCommandPipeServer xipc_create_server failed. serverName %s", server_path);
        return false;
    }
    
    _cmdPipe = cmdPipe;
    return true;
}

void MirrorAppServer::DestroyCommandPipeServer() {
    if (_cmdPipe == NULL) {
        return;
    }
    
    xipc_destroy(_cmdPipe);
    _cmdPipe = NULL;
}

bool MirrorAppServer::StartIoThread() {
    if (_cmdPipe == NULL) {
        return false;
    }
    
    if (_ioThreadStarted) {
        return true;
    }
    
    // ipc 소켓을 기동하기 위한 thread 생성
    int rc = pthread_create(&_ioThread, NULL, &MirrorAppServer::IoThreadEntry, this);
    if (rc != 0) {
        NSLog(@"[MirrorAppServer]::StartIoThread pthread_create failed: %d", rc);
        _ioThreadStarted = 0;
        return false;
    }
    
    _ioThreadStarted = 1;
    return true;
}

void MirrorAppServer::StopIoThread() {
    if (_ioThreadStarted) {
        xipc_end_loop(_cmdPipe);
        
        pthread_join(_ioThread, NULL);
        _ioThreadStarted = 0;
    }
}

void MirrorAppServer::SignalIoThreadToStop() {
    if (_cmdPipe == NULL) {
        return;
    }
    
    // 리스닝 소켓을 닫아 poll이 EBADF로 실패하도록 유도
    // 주의: 여기서 xipc_destroy를 호출하지 않음(루프가 사용하는 메모리를 파괴하면 안 됨)
    if (_cmdPipe->fd > 0) {
        close(_cmdPipe->fd);
        _cmdPipe->fd = -1;
    }
    
    // wakeup 파이프에 바이트를 써서 즉시 poll을 깨우기
    // write는 non-blocking으로 설정되어 있음
    if (_cmdPipe->wakeup_pipe[1] > 0) {
        const char c = 'S';
        write(_cmdPipe->wakeup_pipe[1], &c, sizeof(char));
    }
}

void* MirrorAppServer::IoThreadEntry(void* arg) {
    MirrorAppServer* _this = (MirrorAppServer*)arg;
    if (_this == NULL || _this->_cmdPipe == NULL) {
        return NULL;
    }
    
    xipc_loop(_this->_cmdPipe);
    return NULL;
}

int MirrorAppServer::OnClientConnected(xipc_t* t, xipc_t* client) {
    MirrorAppServer* _this = (MirrorAppServer*)t->user_data;
    
    if (_this->_client != NULL) {
        struct MirrorAppClientCtx* oldCtx = (struct MirrorAppClientCtx*)_this->_client->user_data;
        oldCtx->ScreenRecorder->SendDisconnectMsgToClient();
        _this->_client = NULL;
    }
    
    struct MirrorAppClientCtx* ctx = (struct MirrorAppClientCtx*)malloc(sizeof(struct MirrorAppClientCtx));
    
    ctx->ScreenRecorder = _this->CreateScreenRecorder();
    
    client->user_data = (void*)ctx;
    
    _this->_client = client;

    return 0;
}

int MirrorAppServer::OnClientDisconnected(xipc_t* t, xipc_t* client) {
    MirrorAppServer* _this = (MirrorAppServer*)t->user_data;
    _this->_client = NULL;

    if (client->user_data == NULL) return 0;
    
    struct MirrorAppClientCtx* ctx = (struct MirrorAppClientCtx*)client->user_data;
    delete ctx->ScreenRecorder;
    free(ctx);
    client->user_data = NULL;

    return 0;
}

int MirrorAppServer::OnMessageReceived(xipc_t* t, xipc_t* client, void* data, int len) {
    if (t == NULL || data == NULL || len <= 0) {
        return 0;
    }
    
    if (client == NULL || client->user_data == NULL) {
        return 0;
    }
    
    struct MirrorAppClientCtx* ctx = (struct MirrorAppClientCtx*)client->user_data;
    
    xstream_t* cmd = xstream_create_for_read(data, len);
    if (cmd == NULL) {
        return 0;
    }
    
    MirrorAppServer* _this = (MirrorAppServer*)t->user_data;
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
        case OSXRDP_CMDTYPE_SCREEN: {
            ctx->ScreenRecorder->HandleCommand(client, cmd);
            break;
        }
        default:
            break;
    }
    
    xstream_free(cmd);
    return 0;
}

// 상태 접근 헬퍼
void MirrorAppServer::SetState(State s) {
    pthread_mutex_lock(&_stateLock);
    _state = s;
    pthread_mutex_unlock(&_stateLock);
}

MirrorAppServer::State MirrorAppServer::GetState() {
    pthread_mutex_lock(&_stateLock);
    State s = _state;
    pthread_mutex_unlock(&_stateLock);
    return s;
}

bool MirrorAppServer::IsState(State s) {
    pthread_mutex_lock(&_stateLock);
    bool same = (_state == s);
    pthread_mutex_unlock(&_stateLock);
    return same;
}

ScreenRecorder* MirrorAppServer::CreateScreenRecorder() {
    if (@available(macOS 14.0,*)) {
        return new ScreenRecorder(false);
    }
    else {
        return new ScreenRecorder(true);
    }
}
