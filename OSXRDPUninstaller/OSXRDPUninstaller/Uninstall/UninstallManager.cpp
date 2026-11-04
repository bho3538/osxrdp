#include "UninstallManager.h"
#include <stdio.h>
#include <vector>
#include <mach-o/dyld.h>
#include <limits.h>

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

bool UninstallManager::DoUninstall() {
    if (_authRef == NULL) {
        _errmsg = "Elevated privileges required";
        
        return false;
    }
    
    UnregisterDaemon("/Library/LaunchDaemons/com.byungho.osxrdp.plist");
    UnregisterDaemon("/Library/LaunchDaemons/com.byungho.osxrdp.sessionmanager.plist");
    UnregisterDaemon("/Library/LaunchAgents/com.byungho.osxrdp.lockscreen.plist");
    RemoveFile("/Library/LaunchDaemons/com.byungho.osxrdp.plist");
    RemoveFile("/Library/LaunchDaemons/com.byungho.osxrdp.sessionmanager.plist");
    RemoveFile("/Library/LaunchAgents/com.byungho.osxrdp.lockscreen.plist");
    TerminateProcess("/Applications/osxrdp/OSXRDP.app/Contents/MacOS/OSXRDP");
    TerminateProcess("/Applications/osxrdp/OSXRDP.app/Contents/MacOS/xrdp");
    
    // xrdp 전용 계정 삭제
    char executable[PATH_MAX];
    uint32_t size = sizeof(executable);
    char* args[] = { (char*)"--remove-service-account", NULL };
    if(_NSGetExecutablePath(executable, &size) != 0 || Execute(executable, args) != 0) {
        _errmsg = "Failed to remove the service account or its installation records.";
        return false;
    }

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
    return true;
}


int UninstallManager::Execute(const char* path, char* args[]) {
    char script[] = "\"$@\"; printf '\\nOSXRDP_STATUS:%d\\n' \"$?\"";
    std::vector<char*> command;
    command.push_back((char*)"-p");
    command.push_back((char*)"-c");
    command.push_back(script);
    command.push_back((char*)"osxrdp");
    command.push_back((char*)path);
    for(int i = 0; args[i] != NULL; i++)
        command.push_back(args[i]);
    command.push_back(NULL);

    FILE* pipe = NULL;
    if(AuthorizationExecuteWithPrivileges(_authRef, "/bin/bash", kAuthorizationFlagDefaults, &command[0], &pipe) != errAuthorizationSuccess || pipe == NULL) {
        return -1;
    }

    int result = -1;
    char line[256];
    while(fgets(line, sizeof(line), pipe) != NULL) {
        int status;
        if(sscanf(line, "OSXRDP_STATUS:%d", &status) == 1) {
            result = status;
        }
    }

    if(ferror(pipe))
        result = -1;
    
    fclose(pipe);
    return result;
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
