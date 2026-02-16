
#ifndef StatusManager_h
#define StatusManager_h

enum class OSXUPStatus {
    INIT,
    REQUESTSESSION,
    AGENT_CONNECTING_LOCKSCREEN,
    AGENT_CONNECTED_LOCKSCREEN,
    AGENT_RECORD_LOCKSCREEN,
    AGENT_CONNECTING,
    AGENT_CONNECTED,
    AGENT_RECORD,
    REQ_TERMINATE,
};

class StatusManager {
public:
    StatusManager();
    ~StatusManager();
    
    bool CheckInitStatus();
    
    // 화면 출력이 가능한 상태인지 확인
    bool CheckCanPaint();
    
    // 연결을 종료해야 하는 상태인지 확인
    bool CheckNeedTerminate();
    
    // 잠금 화면을 출력하는 상태인지 확인
    bool CheckInLockscreen();
    
    // 잠금 화면이 종료되어 재연결을 시도해야하는 상태인지 확인
    bool CheckReconnection();
    
    // 세션 요청 상태 설정
    void SetRequestSession();
    
    // 에이전트 연결중 상태 설정
    void SetAgentConnecting(bool lockscreen);
    
    // 에이전트 연결완료 상태 설정
    void SetAgentConnected(bool lockscreen);
    
    // 에이전트 녹화 시작 상태 설정
    void SetAgentRecordStart(bool lockscreen);
    
    // 연결 종료 상태 설정
    void SetStopping();
    
    // 출력 제한 상태 설정
    void SetSuppressed(bool suppress);
    
private:
    OSXUPStatus _status;
};

#endif /* StatusManager_h */
