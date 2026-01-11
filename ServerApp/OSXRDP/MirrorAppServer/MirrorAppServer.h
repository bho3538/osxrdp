#ifndef MirrorAppServer_hpp
#define MirrorAppServer_hpp

#include "ipc.h"
#include "../ScreenRecorder/ScreenRecorder.h"
#include <pthread.h>

struct MirrorAppClientCtx {
    ScreenRecorder* ScreenRecorder; // currently only one.
};

class MirrorAppServer {
public:
    MirrorAppServer();
    ~MirrorAppServer();
    
    void Start();
    void Stop();
    bool IsRunning();
    
private:
    // 상태 머신
    enum State {
        State_Idle = 0,
        State_Starting,
        State_Running,
        State_Stopping,
        State_Stopped
    };
    
    // IPC
    xipc_t* _cmdPipe;
    
    xipc_t* _client; // currently, only one client can connect per each account
    
    // 동기화/스레드
    pthread_mutex_t _stateLock;
    pthread_t _ioThread;
    int _ioThreadStarted;
    State _state;
    
    // 내부 헬퍼
    bool CreateCommandPipeServer();
    void DestroyCommandPipeServer();
    
    bool StartIoThread();
    void StopIoThread();
    void SignalIoThreadToStop();
    
    static void* IoThreadEntry(void* arg);
    
    // 상태 접근 헬퍼
    void SetState(State s);
    State GetState();
    bool IsState(State s);
    
    // xipc 콜백
    static int OnClientConnected(xipc_t* t, xipc_t* client);
    static int OnClientDisconnected(xipc_t* t, xipc_t* client);
    static int OnMessageReceived(xipc_t* t, xipc_t* client, void* data, int len);
};

#endif /* MirrorAppServer_hpp */
