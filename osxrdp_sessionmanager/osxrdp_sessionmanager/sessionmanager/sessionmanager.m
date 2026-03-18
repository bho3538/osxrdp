//
//  sessionmanager.m
//  osxrdp_sessionmanager
//
//  Created by byungho on 1/24/26.
//

#include "../pch.h"
#include "sessionmanager.h"

#import <CoreGraphics/CoreGraphics.h>
#import <OpenDirectory/OpenDirectory.h>
#include <sys/types.h>

// private api
extern CFArrayRef CGSCopySessionList(void) CF_RETURNS_RETAINED;
extern CGError CGSCreateSessionWithDataAndOptions(CFStringRef, CFArrayRef, void*, void*, void*, int, int*, int*);
extern CGError CGSReleaseSession(int session);

// private const
extern const NSString* kCGSSessionIDKey;
extern const NSString* kCGSSessionLongUserNameKey;

NSString* osxrdp_normalize_username(NSString* username) {
    if (username == nil) {
        return nil;
    }
    
    return [username precomposedStringWithCanonicalMapping];
}

ODRecord* osxrdp_find_user_record(ODNode* node, NSString* username) {
    if (node == nil || username == nil || username.length == 0) {
        return nil;
    }
    
    NSError* error = nil;
    ODQuery* recordNameQuery = [ODQuery queryWithNode:node
                                            forRecordTypes:kODRecordTypeUsers
                                            attribute:kODAttributeTypeRecordName
                                            matchType:kODMatchEqualTo
                                            queryValues:username
                                            returnAttributes:@[ kODAttributeTypeUniqueID ]
                                            maximumResults:2
                                            error:&error];
    if (recordNameQuery != nil) {
        NSArray<ODRecord*>* results = [recordNameQuery resultsAllowingPartial:NO error:&error];
        if (results.count == 1) {
            return results.firstObject;
        }
    }
    
    error = nil;
    ODQuery* fullNameQuery = [ODQuery queryWithNode:node
                                            forRecordTypes:kODRecordTypeUsers
                                            attribute:kODAttributeTypeFullName
                                            matchType:kODMatchEqualTo
                                            queryValues:username
                                            returnAttributes:@[ kODAttributeTypeUniqueID ]
                                            maximumResults:2
                                            error:&error];
    if (fullNameQuery == nil) {
        return nil;
    }
    
    NSArray<ODRecord*>* results = [fullNameQuery resultsAllowingPartial:NO error:&error];
    if (results.count != 1) {
        return nil;
    }
    
    return results.firstObject;
}

BOOL osxrdp_copy_user_uid(ODNode* node, NSString* username, uid_t* uid) {
    if (node == nil || username == nil || uid == NULL) {
        return NO;
    }
    
    ODRecord* record = osxrdp_find_user_record(node, osxrdp_normalize_username(username));
    if (record == nil) {
        return NO;
    }
    
    NSError* error = nil;
    NSArray* values = [record valuesForAttribute:kODAttributeTypeUniqueID error:&error];
    if (values.count == 0) {
        return NO;
    }
    
    id firstValue = values.firstObject;
    NSString* uidString = nil;
    if ([firstValue isKindOfClass:[NSString class]]) {
        uidString = (NSString*)firstValue;
    }
    else if ([firstValue isKindOfClass:[NSData class]]) {
        uidString = [[NSString alloc] initWithData:(NSData*)firstValue encoding:NSUTF8StringEncoding];
    }
    
    if (uidString == nil || uidString.length == 0) {
        return NO;
    }
    
    *uid = (uid_t)uidString.integerValue;
    return YES;
}

BOOL osxrdp_usernames_match(ODNode* node, NSString* requestedUsername, uid_t requestedUid, BOOL hasRequestedUid, NSString* sessionUsername) {
    if (requestedUsername == nil || sessionUsername == nil) {
        return NO;
    }
    
    if (hasRequestedUid) {
        uid_t sessionUid = 0;
        if (osxrdp_copy_user_uid(node, sessionUsername, &sessionUid) == YES) {
            return requestedUid == sessionUid;
        }
    }
    
    NSString* normalizedRequested = osxrdp_normalize_username(requestedUsername);
    NSString* normalizedSession = osxrdp_normalize_username(sessionUsername);
    
    if (normalizedRequested == nil || normalizedSession == nil) {
        return NO;
    }
    
    return [normalizedRequested isEqualToString:normalizedSession];
}

BOOL osxrdp_is_loginwindow_user(NSString* sessionUsername) {
    NSString* normalizedSession = osxrdp_normalize_username(sessionUsername);
    if (normalizedSession == nil) {
        return NO;
    }
    
    return [normalizedSession isEqualToString:@"root"] || [normalizedSession isEqualToString:@"Unknown User"]; // macOS 12 first boot???
}

int osxrdp_sessionmanager_getsessioninfo(const char* username, session_info_t* sessionInfo) {
    if (username == NULL || sessionInfo == NULL) {
        return 1;
    }
    
    @autoreleasepool {
        NSString* requestedUsername = [[NSString alloc] initWithUTF8String:username];
        if (requestedUsername == nil || requestedUsername.length == 0) {
            dzlog_error("[osxrdp_sessionmanager_getsessioninfo] invalid username encoding");
            return 1;
        }
        
        dzlog_info("[osxrdp_sessionmanager_getsessioninfo] username: %s", username);
        
        // 요청된 계정의 uid 를 조회 (기존 : 계정명 비교)
        NSError* error = nil;
        ODNode* authNode = [ODNode nodeWithSession:[ODSession defaultSession]
                                                type:kODNodeTypeAuthentication
                                                error:&error];
        uid_t requestedUid = 0;
        BOOL hasRequestedUid = NO;
        if (authNode != nil) {
            hasRequestedUid = osxrdp_copy_user_uid(authNode, requestedUsername, &requestedUid);
        }
        
        // 컴퓨터의 gui 세션을 enum
        NSArray<NSDictionary*>* sessions = CFBridgingRelease(CGSCopySessionList());
        if (sessions == nil || sessions.count == 0) {
            dzlog_error("[osxrdp_sessionmanager_getsessioninfo] enum sessions is null or empty");
            
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
            NSString* session_username = session[kCGSSessionLongUserNameKey];
            NSNumber* sessionId = session[kCGSSessionIDKey];
            
            dzlog_info("[osxrdp_sessionmanager_getsessioninfo] enum session. username : %s, sessionId : %d", session_username != nil ? session_username.UTF8String : "(null)", sessionId.intValue);
            
            // 요청된 계정의 uid 와 enum 한 세션의 사용자 uid 를 비교
            if (session_username != nil && osxrdp_usernames_match(authNode, requestedUsername, requestedUid, hasRequestedUid, session_username)) {
                
                NSNumber* isLogined = session[@"kCGSessionLoginDoneKey"];
                NSNumber* isConsoleSession = session[@"kCGSSessionOnConsoleKey"];
                
                dzlog_info("[osxrdp_sessionmanager_getsessioninfo] found my session info. id: %d, isLogined: %d, console: %d", sessionId.intValue, isLogined.intValue, isConsoleSession.intValue);
                
                mySessionId = sessionId.intValue;
                isMySessionLogined = isLogined.intValue;
                isMySessionConsole = isConsoleSession.intValue;
            }
            else if (session_username != nil && osxrdp_is_loginwindow_user(session_username)) {
                NSNumber* isConsoleSession = session[@"kCGSSessionOnConsoleKey"];
                
                dzlog_info("[osxrdp_sessionmanager_getsessioninfo] found lockscreen session info. id: %d, console: %d", sessionId.intValue, isConsoleSession.intValue);
                
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
    
    dzlog_info("[osxrdp_sessionmanager_getsessioninfo] session not found");
    
    return 1;
}

int osxrdp_sessionmanager_createsession(session_info_t* created_sessionInfo) {
    if (created_sessionInfo == NULL) return 1;
    
    @autoreleasepool {
        
        dzlog_info("[osxrdp_sessionmanager_createsession] create session");
        
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
            dzlog_error("[osxrdp_sessionmanager_createsession] could not create new user session");
            return 1;
        }
        
        created_sessionInfo->sessionId = sessionId;
        created_sessionInfo->isLogined = 0;
        
        dzlog_info("[osxrdp_sessionmanager_createsession] create session success. sessionid : %d", sessionId);
        
        return 0;
    }
}

void osxrdp_sessionmanager_releasesession(int sessionId) {
    
    // 세션이 로그인 되어있는지 확인 (그냥 날려버리면 사용자 작업이 유실)
    @autoreleasepool {
        
        dzlog_info("[osxrdp_sessionmanager_releasesession] release session %d", sessionId);
        
        // 컴퓨터의 gui 세션을 enum
        NSArray<NSDictionary*>* sessions = CFBridgingRelease(CGSCopySessionList());
        if (sessions == nil) {
            return;
        }
        
        // 요청된 세션 id 를 사용하여 세션 정보 조회
        for (NSDictionary* session in sessions) {
            NSString* current_sessionId = session[kCGSSessionIDKey];
            NSString* current_isLogined = session[@"kCGSessionLoginDoneKey"];
            
            // 아직 로그인되지 않은 세션일 경우 날려버리기
            if (current_sessionId.intValue == sessionId && current_isLogined.intValue == 0) {
                dzlog_info("[osxrdp_sessionmanager_releasesession] release session completed %d", sessionId);
                
                CGSReleaseSession(sessionId);
                break;
            }
        }
    }
}
