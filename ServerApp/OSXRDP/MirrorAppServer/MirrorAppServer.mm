#include "MirrorAppServer.h"
#include "xstream.h"
#import <Foundation/Foundation.h>
#include <unistd.h>
#include <string.h>
#include <dlfcn.h>
#include <atomic>
#include "../Utils/PermissionCheckUtils.h"
#include "osxrdp/packet.h"
#include "utils.h"

extern int g_Lockscreen;

static const char* kTrustedClientTeamId = "33X7M69J4B";
static const char* kTrustedClientSigningIdentifier = "xrdp";

static const char* kLoginFrameworkPath = "/System/Library/PrivateFrameworks/login.framework/login";
static const int kLockScreenDelayAfterDisconnectSec = 5;

// Bumped on every client connect, active-client disconnect, and server stop.
// The delayed lock block below only locks the screen when the generation is
// unchanged, i.e. no reconnect or teardown happened while the lock was pending.
// Kept at file scope (not on the instance) so the block does not dangle when
// StopRemoteConnectionServerService deletes the server.
static std::atomic<uint64_t> g_sessionGeneration(0);

// Lock the OS screen so the console is not left unlocked after a remote
// session ends. SACLockScreenImmediate is a private API in login.framework,
// so resolve it at runtime instead of linking against the framework.
static void LockOsScreen() {
    void* handle = dlopen(kLoginFrameworkPath, RTLD_LAZY);
    if (handle == NULL) {
        NSLog(@"[MirrorAppServer::LockOsScreen] failed to load login framework: %s", dlerror());
        return;
    }

    int (*lockScreenImmediate)(void) = (int (*)(void))dlsym(handle, "SACLockScreenImmediate");
    if (lockScreenImmediate == NULL) {
        NSLog(@"[MirrorAppServer::LockOsScreen] SACLockScreenImmediate not found: %s", dlerror());
        dlclose(handle);
        return;
    }

    int rc = lockScreenImmediate();
    NSLog(@"[MirrorAppServer::LockOsScreen] SACLockScreenImmediate rc=%d", rc);

    dlclose(handle);
}

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
    if (is_root_process() == 0 && PermissionCheckUtils::HasAllPermissionToStartRemoteConnection() == false) {
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

    // Invalidate any pending delayed screen lock scheduled by OnClientDisconnected
    g_sessionGeneration.fetch_add(1);

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

bool MirrorAppServer::HasRemoteClipboardFiles() {
    ClipboardManager* clipboard = GetClipboardManager();
    return clipboard != NULL && clipboard->HasRemoteFiles();
}

void MirrorAppServer::StartRemoteClipboardFileCopy() {
    ClipboardManager* clipboard = GetClipboardManager();
    if (clipboard != NULL) {
        clipboard->StartRemoteFileCopy();
    }
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
    
    if (get_object_name_by_sessionid("/tmp/osxrdp", server_path, 512, is_root_process()) == 0) {
        NSLog(@"[MirrorAppServer]::CreateCommandPipeServer get_object_name_by_sessionid failed.");
        return false;
    }

    if (xipc_create_server(cmdPipe, server_path, OnClientConnected, OnClientDisconnected, OnClientAuthorize, OnClientRejected) != 0) {
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
    
    NSLog(@"[MirrorAppServer]::StartIoThread");
    
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
    
    xipc_end_loop(_cmdPipe);
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
    @autoreleasepool {
        MirrorAppServer* _this = (MirrorAppServer*)t->user_data;
        
        NSLog(@"[MirrorAppServer::OnClientConnected] new client connected");
        
        if (_this->_client != NULL) {
            struct MirrorAppClientCtx* oldCtx = (struct MirrorAppClientCtx*)_this->_client->user_data;
            oldCtx->ScreenRecorder->SendDisconnectMsgToClient();
            _this->_client = NULL;
        }
        
        struct MirrorAppClientCtx* ctx = (struct MirrorAppClientCtx*)malloc(sizeof(struct MirrorAppClientCtx));
        
        ctx->ScreenRecorder = _this->CreateScreenRecorder();
        ctx->Clipboard = new ClipboardManager();
        ctx->Audio = new AudioManager();
        
        client->user_data = (void*)ctx;
        
        _this->_client = client;
        g_sessionGeneration.fetch_add(1);

        return 0;
    }
}

int MirrorAppServer::OnClientAuthorize(xipc_t* t, xipc_t* client) {
    (void)t;
#if DEBUG
    return 0;
#else
    // 클라이언트가 유효한 서명을 가지고 있는지 확인. (악의적인 프로세스의 접속 방지)
    return xipc_is_client_signed_by(client, kTrustedClientTeamId, kTrustedClientSigningIdentifier);
#endif
}

int MirrorAppServer::OnClientRejected(xipc_t* t, xipc_t* client) {
    (void)t;

    pid_t peerPid = 0;
    if (xipc_get_peer_pid(client, &peerPid) == 0) {
        NSLog(@"[MirrorAppServer::OnClientRejected] rejected unauthorized client pid=%d", (int)peerPid);
    }
    else {
        NSLog(@"[MirrorAppServer::OnClientRejected] rejected unauthorized client");
    }

    return 0;
}

int MirrorAppServer::OnClientDisconnected(xipc_t* t, xipc_t* client) {
    @autoreleasepool {
        MirrorAppServer* _this = (MirrorAppServer*)t->user_data;
        NSLog(@"[MirrorAppServer::OnClientDisconnected] client disconnected");

        bool wasActiveClient = (_this->_client == client);
        if (wasActiveClient) {
            _this->_client = NULL;
            g_sessionGeneration.fetch_add(1);
        }

        // Let the OS screen enter lock mode when the remote session ends.
        // Skip for the loginwindow agent instance (already at the login screen),
        // for takeover disconnects where a new client already replaced this one,
        // and for server teardown (the local user stopping the service or the
        // app terminating should not lock the console).
        // The lock is delayed and the generation is re-checked so a quick
        // reconnect (e.g. an xrdp takeover that closes the old socket before
        // the new client attaches) or a teardown that starts after this check
        // does not lock the screen of the freshly connected session.
        // The generation must be loaded before the IsState check: Stop() sets
        // State_Stopping before bumping the generation, so a teardown that
        // slips past the IsState check here is still caught by the generation
        // compare in the block below.
        uint64_t scheduledGeneration = g_sessionGeneration.load();
        if (wasActiveClient && g_Lockscreen == 0 && _this->IsState(State_Stopping) == false) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kLockScreenDelayAfterDisconnectSec * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{
                if (g_sessionGeneration.load() != scheduledGeneration) {
                    NSLog(@"[MirrorAppServer::OnClientDisconnected] skip screen lock. session state changed");
                    return;
                }

                LockOsScreen();
            });
        }

        if (client->user_data == NULL)
            return 0;
        
        struct MirrorAppClientCtx* ctx = (struct MirrorAppClientCtx*)client->user_data;
        if (ctx == NULL)
            return 0;
        
        if (ctx->ScreenRecorder->Stop() == true) {
            delete ctx->ScreenRecorder;
        }
        else {
            // A capture callback may still be running — deliberately leak the
            // recorder manager instead of freeing memory a live callback can touch
            NSLog(@"[MirrorAppServer::OnClientDisconnected] recorder stop failed. leak recorder manager");
        }
        delete ctx->Clipboard;
        delete ctx->Audio;
        free(ctx);
        
        client->user_data = NULL;

        return 0;
    }
}

int MirrorAppServer::OnMessageReceived(xipc_t* t, xipc_t* client, void* data, int len) {
    @autoreleasepool {
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
            NSLog(@"[MirrorAppServer::OnMessageReceived] invalid status");

            xstream_free(cmd);
            return 0;
        }
        
        int cmdType = xstream_readInt32(cmd);
            
        switch (cmdType) {
            case OSXRDP_CMDTYPE_SCREEN: {
                ctx->ScreenRecorder->HandleCommand(client, cmd);
                break;
            }
            case OSXRDP_CMDTYPE_CLIPBOARD: {
                ctx->Clipboard->HandleCommand(client, cmd);
                break;
            }
            case OSXRDP_CMDTYPE_AUDIO: {
                ctx->Audio->HandleCommand(client, cmd);
                break;
            }
            default:
                break;
        }
        
        xstream_free(cmd);
        return 0;
    }
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

ScreenRecorderManager* MirrorAppServer::CreateScreenRecorder() {
    // ScreenCaptureKit 은 macOS 12.3 이상부터 사용할 수 있지만, 버그가 있어 사실상 macOS 14 이상부터 사용할 수 있음. (필터링 버그)
    // 따라서 구형 os 에서는 레거시 API 를 사용하여 화면을 녹화하도록 구성. (성능 차이는 크게 나지 않는것 같음)
    if (@available(macOS 14.0,*)) {
        if (is_root_process() == 1) {
            return new ScreenRecorderManager(true);
        }
        else {
            return new ScreenRecorderManager(false);
        }
    }
    else {
        return new ScreenRecorderManager(true);
    }
}

ClipboardManager* MirrorAppServer::GetClipboardManager() {
    if (_client == NULL || _client->user_data == NULL) {
        return NULL;
    }

    struct MirrorAppClientCtx* ctx = (struct MirrorAppClientCtx*)_client->user_data;
    return ctx != NULL ? ctx->Clipboard : NULL;
}
