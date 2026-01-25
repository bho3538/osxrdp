//
//  sessionmanager.m
//  osxrdp_sessionmanager
//
//  Created by byungho on 1/24/26.
//

#include "sessionmanager.h"

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

extern NSArray<NSDictionary*>* CGSCopySessionList(void);
extern CGError CGSCreateSessionWithDataAndOptions(CFStringRef, CFArrayRef, void*, void*, void*, int, int*, int*);
extern CGError CGSReleaseSession(int session);

extern const NSString* kCGSSessionIDKey;
extern const NSString* kCGSSessionLongUserNameKey;

int osxrdp_sessionmanager_getsessioninfo(const char* username, session_info_t* sessionInfo) {
    if (username == NULL || sessionInfo == NULL) {
        return 1;
    }
    
    @autoreleasepool {
        // 컴퓨터의 gui 세션을 enum
        NSArray<NSDictionary*>* sessions = CGSCopySessionList();
        if (sessions == nil) {
            return -1;
        }
        
        // 세션에서 요청된 계정의 세션정보를 조회
        for (NSDictionary* session in sessions) {
            const NSString* session_username = session[kCGSSessionLongUserNameKey];
            if (session_username != nil && !strcmp(session_username.UTF8String, username)) {
                
                NSString* sessionId = session[kCGSSessionIDKey];
                NSString* isLogined = session[@"kCGSessionLoginDoneKey"];
                sessionInfo->sessionId = sessionId.intValue;
                sessionInfo->isLogined = isLogined.intValue;
                
                return 0;
            }
        }
    }
    
    return 1;
}

int osxrdp_sessionmanager_createsession(session_info_t* created_sessionInfo) {
    if (created_sessionInfo == NULL) return 1;
    
    @autoreleasepool {
        // Lock screen window
        NSString *path = @"/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow";
        NSArray *args = @[path, @"-console"];

        int sessionId = 0;
        int connection = 0;
        int options = 3; // 2: background session, 3 : foreground session

        CGError err = CGSCreateSessionWithDataAndOptions(
            (__bridge CFStringRef)path,
            (__bridge CFArrayRef)args,
            NULL, NULL, NULL,
            options,
            &sessionId,
            &connection
        );

        if (err != 0) {
            return 1;
        }
        
        created_sessionInfo->sessionId = sessionId;
        created_sessionInfo->isLogined = 0;
        
        return 0;
    }
}

void osxrdp_sessionmanager_releasesession(session_info_t* sessionInfo) {
    if (sessionInfo == NULL) return;
    
    CGSReleaseSession(sessionInfo->sessionId);
}
