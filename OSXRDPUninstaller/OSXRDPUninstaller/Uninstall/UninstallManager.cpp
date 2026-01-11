#include "UninstallManager.h"

UninstallManager::UninstallManager() :
    _authRef(NULL),
    _errmsg(NULL)
{
    
}

UninstallManager::~UninstallManager() {
    
}

bool UninstallManager::Elevate() {
    OSStatus status = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment, kAuthorizationFlagDefaults, &_authRef);
    if (status != errAuthorizationSuccess) {
        return false;
    }
    
    AuthorizationItem authItem = {
        kAuthorizationRightExecute,
        0,
        NULL,
        0
    };
    
    AuthorizationRights authRights = {
        1,
        &authItem
    };
    
    AuthorizationFlags flags = kAuthorizationFlagInteractionAllowed | kAuthorizationFlagPreAuthorize | kAuthorizationFlagExtendRights;
    status = AuthorizationCopyRights(_authRef, &authRights, kAuthorizationEmptyEnvironment, flags, NULL);
    
    if (status != errAuthorizationSuccess) {
        return false;
    }
    
    return true;
}

void UninstallManager::DeElevate() {
    if (_authRef == NULL) return;
    
    AuthorizationFree(_authRef, kAuthorizationFlagDefaults);
    _authRef = NULL;
}

void UninstallManager::DoUninstall() {
    if (_authRef == NULL) {
        _errmsg = "Elevated privileges required";
        
        return;
    }
    
    UnregisterDaemon("/Library/LaunchDaemons/com.byungho.osxrdp.plist");
    RemoveFile("/Library/LaunchDaemons/com.byungho.osxrdp.plist");
    TerminateProcess("/Applications/osxrdp/OSXRDP.app/Contents/MacOS/OSXRDP");
    TerminateProcess("/Applications/osxrdp/OSXRDP.app/Contents/MacOS/xrdp");
    RemoveDirectory("/etc/xrdp");
    RemoveDirectory("/usr/local/lib/xrdp");
    RemoveDirectory("/usr/local/share/xrdp");
    RemoveFile("/var/log/xrdp.log");
    RemoveDirectory("/Applications/osxrdp");
}


bool UninstallManager::TerminateProcess(const char* path) {
    char* args[] = { "-9" , "-f", (char*)path, NULL};

    AuthorizationExecuteWithPrivileges(_authRef, "/usr/bin/pkill", kAuthorizationFlagDefaults, args, NULL);
    
    return true;
}

bool UninstallManager::RemoveDirectory(const char* path) {
    char* args[] = { "-rf" , (char*)path, NULL};

    AuthorizationExecuteWithPrivileges(_authRef, "/bin/rm", kAuthorizationFlagDefaults, args, NULL);
    
    return true;
}

bool UninstallManager::RemoveFile(const char* path) {
    char* args[] = { "-f" , (char*)path, NULL};

    AuthorizationExecuteWithPrivileges(_authRef, "/bin/rm", kAuthorizationFlagDefaults, args, NULL);
    
    return true;
}

bool UninstallManager::UnregisterDaemon(const char* path) {
    char* args[] = { "bootout" , (char*)path, NULL};

    AuthorizationExecuteWithPrivileges(_authRef, "/bin/launchctl", kAuthorizationFlagDefaults, args, NULL);
    
    return true;
}
