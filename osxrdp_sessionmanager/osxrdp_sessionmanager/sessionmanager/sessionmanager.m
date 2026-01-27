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
        
        // 주의!
        // 한 컴퓨터에 콘솔 세션에는 단 하나의 잠금 화면만 있어야 한다. (그렇지 않은 경우 무한으로 깜박거림...)
        // 요청된 계정의 세션이 있는 경우
        //   잠긴 경우 :
        //     다른 잠금 화면이 있는 경우 : 해당 잠금 화면을 사용
        //     다른 잠금 화면이 없는 경우 : 잠금 화면 만들기 (세션 생성)
        //   잠기지 않은 경우 : 그대로 사용
        // 요청된 계정의 세션이 없는 경우
        //   다른 잠금 화면이 있는 경우 : 해당 잠금 화면을 사용
        //   다른 잠금 화면이 없는 경우 : 잠금 화면 만들기 (세션 생성)
        
        int mySessionId = -1;
        int isMySessionLogined = 0;
        int isMySessionConsole = 0;
        
        int loginWindowSessionId = -1;
        int isLoginWindowSessionConsole = 0;
        
        for (NSDictionary* session in sessions) {
            const NSString* session_username = session[kCGSSessionLongUserNameKey];
            if (session_username != nil && !strcmp(session_username.UTF8String, username)) {
                
                NSString* sessionId = session[kCGSSessionIDKey];
                NSString* isLogined = session[@"kCGSessionLoginDoneKey"];
                NSString* isConsoleSession = session[@"kCGSSessionOnConsoleKey"];
                
                NSLog(@"[osxrdp_sessionmanager_getsessioninfo] found my session info. id: %@, isLogined: %@, console: %@", sessionId, isLogined, isConsoleSession);

                mySessionId = sessionId.intValue;
                isMySessionLogined = isLogined.intValue;
                isMySessionConsole = isConsoleSession.intValue;
            }
            else if (session_username != nil && !strcmp(session_username.UTF8String, "root")) {
                
                NSString* sessionId = session[kCGSSessionIDKey];
                NSString* isConsoleSession = session[@"kCGSSessionOnConsoleKey"];
                
                NSLog(@"[osxrdp_sessionmanager_getsessioninfo] found lockscreen session info. id: %@, console: %@", sessionId, isConsoleSession);

                loginWindowSessionId = sessionId.intValue;
                isLoginWindowSessionConsole = isConsoleSession.intValue;
            }
            
        }
        
        // 요청한 계정의 세션이 있고, 콘솔 세션인 경우
        if (mySessionId != -1 && isMySessionConsole == 1) {
            sessionInfo->isLogined = isMySessionLogined;
            sessionInfo->sessionId = mySessionId;
            
            return 0;
        }
        
        // 요청한 계정의 세션이 없는 경우
        if (loginWindowSessionId != -1 && isLoginWindowSessionConsole == 1) {
            // 다른 잠금 화면이 있는경우
            // 이것을 사용
            sessionInfo->isLogined = 0;
            sessionInfo->sessionId = loginWindowSessionId;
            
            return 0;
        }
        
        // 그렇지 못한 경우 세션을 만들도록 유도
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
