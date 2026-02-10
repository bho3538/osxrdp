
#include "duprun.h"
#include <CoreFoundation/CoreFoundation.h>

struct duprun {
    CFMessagePortRef messagePort;
};

duprun* duprun_initialize(const char* lockname) {
    if (lockname == NULL || strlen(lockname) == 0) {
        return NULL;
    }
    
    Boolean shouldFreeInfo = false;
    CFMessagePortContext ctx = {0, NULL, NULL, NULL, NULL};
    
    CFStringRef kPortName = CFStringCreateWithCString(kCFAllocatorDefault, lockname, kCFStringEncodingUTF8);
    if (kPortName == NULL) {
        return NULL;
    }
    
    CFMessagePortRef local = CFMessagePortCreateLocal(NULL, kPortName, NULL, &ctx, &shouldFreeInfo);
    if (local == NULL) {
        // 중복 실행
        CFRelease(kPortName);
        
        return NULL;
    }
    
    duprun* obj = (duprun*)malloc(sizeof(duprun));
    if (obj == NULL) {
        CFRelease(kPortName);
        
        return NULL;
    }
    
    obj->messagePort = local;
    
    CFRelease(kPortName);
    
    return obj;
}

void duprun_release(duprun* obj) {
    if (obj == NULL) {
        return;
    }
    
    CFRelease(obj->messagePort);
    free(obj);
}
