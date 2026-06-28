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
    UnregisterDaemon("/Library/LaunchDaemons/com.byungho.osxrdp.sessionmanager.plist");
    UnregisterDaemon("/Library/LaunchAgents/com.byungho.osxrdp.lockscreen.plist");
    RemoveFile("/Library/LaunchDaemons/com.byungho.osxrdp.plist");
    RemoveFile("/Library/LaunchDaemons/com.byungho.osxrdp.sessionmanager.plist");
    RemoveFile("/Library/LaunchAgents/com.byungho.osxrdp.lockscreen.plist");
    TerminateProcess("/Applications/osxrdp/OSXRDP.app/Contents/MacOS/OSXRDP");
    TerminateProcess("/Applications/osxrdp/OSXRDP.app/Contents/MacOS/xrdp");
    RemoveDirectory("/Library/Logs/osxrdp");
    RemoveDirectory("/etc/xrdp");
    RemoveDirectory("/etc/osxrdp");
    RemoveDirectory("/usr/local/lib/xrdp");
    RemoveDirectory("/usr/local/share/xrdp");
    RemoveFile("/var/log/xrdp.log");
    RemoveDirectory("/Applications/osxrdp");

    // 설치 흔적(receipt) 및 시스템 리포트 > 설치 목록 정리
    ForgetReceipt("com.byungho.osxrdp.setup");
    CleanInstallHistory("com.byungho.osxrdp");
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

bool UninstallManager::ForgetReceipt(const char* pkgid) {
    char* args[] = { "--forget", (char*)pkgid, NULL };

    AuthorizationExecuteWithPrivileges(_authRef, "/usr/sbin/pkgutil", kAuthorizationFlagDefaults, args, NULL);

    return true;
}

bool UninstallManager::CleanInstallHistory(const char* pkgidPrefix) {
    static char script[1024];
    snprintf(script, sizeof(script),
        "PLIST=/Library/Receipts/InstallHistory.plist; PB=/usr/libexec/PlistBuddy; "
        "[ -f \"$PLIST\" ] || exit 0; "
        "i=0; del=(); "
        "while \"$PB\" -c \"Print :$i\" \"$PLIST\" >/dev/null 2>&1; do "
        "\"$PB\" -c \"Print :$i:packageIdentifiers\" \"$PLIST\" 2>/dev/null | grep -q \"%s\" && del+=($i); "
        "i=$((i+1)); done; "
        "for ((j=${#del[@]}-1;j>=0;j--)); do \"$PB\" -c \"Delete :${del[$j]}\" \"$PLIST\"; done",
        pkgidPrefix);

    char* args[] = { "-c", script, NULL };

    AuthorizationExecuteWithPrivileges(_authRef, "/bin/bash", kAuthorizationFlagDefaults, args, NULL);

    return true;
}
