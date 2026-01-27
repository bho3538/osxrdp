
#include "utils.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <pwd.h>

#include <CoreGraphics/CoreGraphics.h>

extern CFDictionaryRef CGSCopyCurrentSessionDictionary(void);

/*
int get_object_name_by_username(const char* prefix, char* buffer, int cchMax) {
    uid_t uid = getuid();
    
    struct passwd* pwd = getpwuid(uid);
    if (pwd == NULL) return 0;
    
    return get_object_name(pwd->pw_name, prefix, buffer, cchMax);
}

int get_object_name(const char* username, const char* prefix, char* buffer, int cchMax) {
    if (username == NULL || prefix == NULL) return 0;
    
    int prefixLen = (int)strlen(prefix);
    if (prefixLen == 0) return 0;

    int usernameLen = (int)strlen(username);
    if (usernameLen == 0) return 0;
    
    if (prefixLen + usernameLen + (sizeof(char) * 2) > cchMax) return 0;
    
    return sprintf(buffer, "%s_%s", prefix, username);
}
 */

int get_object_name_by_sessionid(const char* prefix, char* buffer, int cchMax) {

    CFDictionaryRef sessionInfo = CGSCopyCurrentSessionDictionary();
    if (sessionInfo == NULL) return 0;

    CFNumberRef sessionIdRef = CFDictionaryGetValue(sessionInfo, CFSTR("kCGSSessionIDKey"));
    if (sessionIdRef == NULL) {
        CFRelease(sessionInfo);
        
        return 0;
    }
    
    int sessionId = 0;
    CFNumberGetValue(sessionIdRef, kCFNumberIntType, &sessionId);
    
    CFRelease(sessionIdRef);
    CFRelease(sessionInfo);
    
    return get_object_name(sessionId, prefix, buffer, cchMax);
}

int get_object_name(int sessionid, const char* prefix, char* buffer, int cchMax) {
    if (prefix == NULL) return 0;
    
    int prefixLen = (int)strlen(prefix);
    if (prefixLen == 0) return 0;
    
    if (prefixLen + 12 + (sizeof(char) * 2) > cchMax) return 0;
    
    return sprintf(buffer, "%s_%d", prefix, sessionid);
}

int is_root_process(void) {
    return getuid() == 0 ? 1 : 0;
}
