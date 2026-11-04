#import <Cocoa/Cocoa.h>
#include "ServiceAccount/ServiceAccountManager.h"
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        if (argc > 1) {
            // 승격된 권한 확인
            if(geteuid() != 0) {
                fprintf(stderr, "Elevated privileges required.\n");
                return 1;
            }
            
            if (!strcmp(argv[1], "--install-service-account")) {
                // xrdp 전용 서비스 계정 추가
                ServiceAccountManager manager;
                return manager.Install() == true ? 0 : 1;
            }
            else if (!strcmp(argv[1], "--remove-service-account")) {
                // xrdp 전용 서비스 계정 삭제
                ServiceAccountManager manager;
                return manager.Remove() == true ? 0 : 1;
            }
            
            printf("invalid args\n");
            return 1;
        }
    }

    return NSApplicationMain(argc, argv);
}
