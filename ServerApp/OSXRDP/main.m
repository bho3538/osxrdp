#import <Cocoa/Cocoa.h>

int g_Lockscreen = 0;

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // Setup code that might create autoreleased objects goes here.
    }
    
    if (argc > 1 && !strcmp(argv[1], "--lockscreen")) {
        g_Lockscreen = 1;
    }
    
    return NSApplicationMain(argc, argv);
}
