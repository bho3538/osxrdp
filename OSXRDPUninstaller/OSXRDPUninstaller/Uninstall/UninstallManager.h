
#ifndef UninstallManager_h
#define UninstallManager_h

#include <Security/Security.h>

class UninstallManager {
public:
    UninstallManager();
    ~UninstallManager();
    
    bool Elevate();
    void DeElevate();
    
    void DoUninstall();
    
private:
    AuthorizationRef _authRef;
    
    const char* _errmsg;
    
    bool TerminateProcess(const char* path);
    bool RemoveDirectory(const char* path);
    bool RemoveFile(const char* path);
    bool UnregisterDaemon(const char* path);
};

#endif /* UninstallManager_h */
