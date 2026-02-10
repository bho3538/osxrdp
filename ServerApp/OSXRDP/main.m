#import <Cocoa/Cocoa.h>
#include "duprun.h"

int g_Lockscreen = 0;

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // Setup code that might create autoreleased objects goes here.
    }
    
    duprun* dup = NULL;
    
    if (argc > 1 && !strcmp(argv[1], "--lockscreen")) {
        g_Lockscreen = 1;
    }
    else {
        // 중복 실행 확인
        dup = duprun_initialize("com.byungho.osxrdp.agent");
        if (dup == NULL) {
            return 1;
        }
    }
    
    int re = NSApplicationMain(argc, argv);
    
    if (dup != NULL) {
        duprun_release(dup);
        dup = NULL;
    }
    
    return re;
}
