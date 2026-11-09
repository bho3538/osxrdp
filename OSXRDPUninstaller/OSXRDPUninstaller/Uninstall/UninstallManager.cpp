#include "UninstallManager.h"
#include <stdio.h>
#include <vector>

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
    
    UnregisterDaemon("system/com.byungho.osxrdp");
    UnregisterDaemon("system/com.byungho.osxrdp.sessionmanager");

    // 잠금 화면 에이전트는 로그인 창 세션에 로드되므로, 실행 중인 에이전트 프로세스의 도메인을 대상으로 내린다.
    char lockscreenScript[] =
        "for pid in $(/usr/bin/pgrep -f '/Applications/osxrdp/OSXRDP.app/Contents/MacOS/[O]SXRDP --lockscreen'); do "
        "/bin/launchctl bootout \"pid/$pid/com.byungho.osxrdp.lockscreen\"; "
        "done; exit 0";
    char* lockscreenArgs[] = { (char*)"-p", (char*)"-c", lockscreenScript, NULL };
    Execute("/bin/bash", lockscreenArgs);

    RemoveFile("/Library/LaunchDaemons/com.byungho.osxrdp.plist");
    RemoveFile("/Library/LaunchDaemons/com.byungho.osxrdp.sessionmanager.plist");
    RemoveFile("/Library/LaunchAgents/com.byungho.osxrdp.lockscreen.plist");
    TerminateProcess("/Applications/osxrdp/OSXRDP.app/Contents/MacOS/OSXRDP");
    TerminateProcess("/Applications/osxrdp/OSXRDP.app/Contents/MacOS/xrdp");

    // 컴퓨터 권한 관리 권한 초기화 (거부 를 눌렀으면 동의 대화상자가 다시 뜨지 않음)
    char* resetArgs[] = { (char*)"reset", (char*)"SystemPolicySysAdminFiles",
                          (char*)"com.byungho.osxrdp.OSXRDPUninstaller", NULL };
    Execute("/usr/bin/tccutil", resetArgs);

    // osxrdp 전용 계정 삭제
    char script[] =
        "for rec in /Users/_osxrdp /Groups/_osxrdp; do "
        "/usr/bin/dscl . -read \"$rec\" RecordName >/dev/null 2>&1 || continue; "
        "[ \"$(/usr/bin/dscl -plist . -read \"$rec\" RealName 2>/dev/null | /usr/bin/plutil -extract dsAttrTypeStandard:RealName.0 raw -o - - 2>/dev/null)\" = 'OSXRDP Service' ] || continue; "
        "/usr/bin/dscl . -delete \"$rec\" || exit 1; "
        "done";
    
    char* args[] = { (char*)"-p", (char*)"-c", script, NULL };
    if(Execute("/bin/bash", args) != 0) {
        _errmsg = "Failed to remove the service account.";
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

bool UninstallManager::UnregisterDaemon(const char* target) {
    char* args[] = { (char*)"bootout", (char*)target, NULL };

    return Execute("/bin/launchctl", args) == 0;
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
