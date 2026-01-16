
#import "AppDelegate.h"
#include "Uninstall/UninstallManager.h"

@interface AppDelegate ()

@property (strong) IBOutlet NSWindow *window;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    // Insert code here to initialize your application
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    // Insert code here to tear down your application
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
    return YES;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (IBAction)onNoBtnClicked:(id)sender {
    // exit
    [[NSApplication sharedApplication] terminate:nil];
}

- (IBAction)onYesBtnClicked:(id)sender {
    UninstallManager manager;
    if(manager.Elevate() == false) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"OSXRDP Uninstaller"];
        [alert setInformativeText:@"Elevated privileges required."];
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
        
        return;
    }
    
    manager.DoUninstall();
    manager.DeElevate();
    
    [[NSApplication sharedApplication] terminate:nil];
}



@end
