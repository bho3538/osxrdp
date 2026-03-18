#import "UserIdentityResolver.h"

#import <Foundation/Foundation.h>
#import <OpenDirectory/OpenDirectory.h>

#include <string.h>

static NSString* osxup_normalize_username(NSString* username) {
    if (username == nil) {
        return nil;
    }

    return [username precomposedStringWithCanonicalMapping];
}

static ODRecord* osxup_find_user_record(ODNode* node, NSString* username) {
    if (node == nil || username == nil || username.length == 0) {
        return nil;
    }

    NSError* error = nil;
    ODQuery* recordNameQuery = [ODQuery queryWithNode:node
                                       forRecordTypes:kODRecordTypeUsers
                                            attribute:kODAttributeTypeRecordName
                                            matchType:kODMatchEqualTo
                                          queryValues:username
                                     returnAttributes:@[ kODAttributeTypeRecordName ]
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
                                   returnAttributes:@[ kODAttributeTypeRecordName ]
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

int osxup_copy_canonical_username(const char* username, char* canonicalUsername, size_t canonicalUsernameSize) {
    if (username == NULL || canonicalUsername == NULL || canonicalUsernameSize == 0) {
        return 1;
    }

    canonicalUsername[0] = '\0';

    @autoreleasepool {
        NSString* inputUsername = [[NSString alloc] initWithUTF8String:username];
        inputUsername = osxup_normalize_username(inputUsername);
        if (inputUsername == nil || inputUsername.length == 0) {
            return 1;
        }

        NSError* error = nil;
        ODNode* node = [ODNode nodeWithSession:[ODSession defaultSession]
                                          type:kODNodeTypeAuthentication
                                         error:&error];
        if (node == nil) {
            return 1;
        }

        ODRecord* record = osxup_find_user_record(node, inputUsername);
        if (record == nil) {
            return 1;
        }

        NSString* recordName = osxup_normalize_username(record.recordName);
        if (recordName == nil || recordName.length == 0) {
            return 1;
        }

        NSData* utf8Data = [recordName dataUsingEncoding:NSUTF8StringEncoding];
        if (utf8Data == nil || utf8Data.length + 1 > canonicalUsernameSize) {
            return 1;
        }

        memcpy(canonicalUsername, utf8Data.bytes, utf8Data.length);
        canonicalUsername[utf8Data.length] = '\0';

        return 0;
    }
}

int osxup_username_matches_canonical_case(const char* username, const char* canonicalUsername) {
    if (username == NULL || canonicalUsername == NULL) {
        return 0;
    }

    @autoreleasepool {
        NSString* inputUsername = osxup_normalize_username([[NSString alloc] initWithUTF8String:username]);
        NSString* resolvedUsername = osxup_normalize_username([[NSString alloc] initWithUTF8String:canonicalUsername]);
        if (inputUsername == nil || resolvedUsername == nil) {
            return 0;
        }

        return [inputUsername isEqualToString:resolvedUsername] ? 1 : 0;
    }
}
