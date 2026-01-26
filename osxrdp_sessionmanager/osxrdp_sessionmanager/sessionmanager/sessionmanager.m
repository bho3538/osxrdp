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
        NSLog(@"[osxrdp_sessionmanager_getsessioninfo] username: %s", username);
        
        // 컴퓨터의 gui 세션을 enum
        NSArray<NSDictionary*>* sessions = CGSCopySessionList();
        if (sessions == nil) {
            NSLog(@"[osxrdp_sessionmanager_getsessioninfo] enum sessions is null");

            return -1;
        }
        
        // 세션에서 요청된 계정의 세션정보를 조회
        for (NSDictionary* session in sessions) {
            const NSString* session_username = session[kCGSSessionLongUserNameKey];
            if (session_username != nil && !strcmp(session_username.UTF8String, username)) {
                
                NSString* sessionId = session[kCGSSessionIDKey];
                NSString* isLogined = session[@"kCGSessionLoginDoneKey"];
                NSString* isConsoleSession = session[@"kCGSSessionOnConsoleKey"];
                
                NSLog(@"[osxrdp_sessionmanager_getsessioninfo] found session info. id: %@, isLogined: %@, console: %@", sessionId, isLogined, isConsoleSession);
                
                if (isConsoleSession.intValue == 0) {
                    // CGSSessionSwitchToSessionID 가 막힌것 같음. (보안 취약점)
                    // 새로운 세션을 만들어 로그인을 유도해야할것 같음
                    return 1;
                }
                
                sessionInfo->sessionId = sessionId.intValue;
                sessionInfo->isLogined = isLogined.intValue;
                
                return 0;
            }
        }
    }
    
    NSLog(@"[osxrdp_sessionmanager_getsessioninfo] session not found");
    
    return 1;
}

int osxrdp_sessionmanager_createsession(session_info_t* created_sessionInfo) {
    if (created_sessionInfo == NULL) return 1;
    
    @autoreleasepool {
        
        NSLog(@"[osxrdp_sessionmanager_createsession] create session");
        
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

void osxrdp_sessionmanager_releasesession(int sessionId) {
    
    // 세션이 로그인 되어있는지 확인 (그냥 날려버리면 사용자 작업이 유실)
    @autoreleasepool {
        
        NSLog(@"[osxrdp_sessionmanager_releasesession] release session %d", sessionId);

        // 컴퓨터의 gui 세션을 enum
        NSArray<NSDictionary*>* sessions = CGSCopySessionList();
        if (sessions == nil) {
            return;
        }
        
        // 요청된 세션 id 를 사용하여 세션 정보 조회
        for (NSDictionary* session in sessions) {
            NSString* current_sessionId = session[kCGSSessionIDKey];
            NSString* current_isLogined = session[@"kCGSessionLoginDoneKey"];
            
            // 아직 로그인되지 않은 세션일 경우 날려버리기
            if (current_sessionId.intValue == sessionId && current_isLogined.intValue == 0) {
                CGSReleaseSession(sessionId);
                break;
            }
        }
    }
}
