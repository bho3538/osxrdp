#import "AppDelegate.h"

#include <signal.h>
#include "RemoteConnection/RemoteConnectionService.h"

#import "UI/Main/MainWindowController.h"

void _handle_sigterm(int signal);

@interface AppDelegate ()
{
    NSStatusItem* _trayMenu;
}

@property (strong) IBOutlet MainWindowController* mainWindowController;

@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    signal(SIGTERM, _handle_sigterm);

    extern int g_Lockscreen;
    if (g_Lockscreen == 1) {
        // hack
        sleep(2);
        
        StartRemoteConnectionServerService();
        return;
    }

    [self setupStatusBar];
    [self.mainWindowController initializeMainUI];
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    StopRemoteConnectionServerService();
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
    return NO;
}

- (void)setupStatusBar {
    _trayMenu = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];

    NSImage* img = [NSImage imageWithSystemSymbolName:@"bolt.horizontal.circle.fill" accessibilityDescription:NSLocalizedString(@"statusbar.icon.accessibility", nil)];
    _trayMenu.button.image = img;

    NSMenu* menus = [[NSMenu alloc] init];
    [menus addItemWithTitle:NSLocalizedString(@"statusbar.menu.title", nil) action:nil keyEquivalent:@""];
    
    [menus addItem:NSMenuItem.separatorItem];
    
    NSMenuItem* openItem = [menus addItemWithTitle:NSLocalizedString(@"statusbar.menu.open", nil) action:@selector(onOpenWindowMenuClicked) keyEquivalent:@""];
    openItem.target = self;
    
    [menus addItem:NSMenuItem.separatorItem];
    
    NSMenuItem* closeItem = [menus addItemWithTitle:NSLocalizedString(@"statusbar.menu.close", nil) action:@selector(onExitMenuClicked) keyEquivalent:@""];
    closeItem.target = self;

    _trayMenu.menu = menus;
}

- (void)onOpenWindowMenuClicked {
    [NSApp activateIgnoringOtherApps:YES];
    [self.mainWindowController showMainWindow];
}

- (void)onExitMenuClicked {
    [[NSApplication sharedApplication] terminate:nil];
}

void _handle_sigterm(int signal) {
    NSLog(@"[OSXRDP] on sigterm");
    StopRemoteConnectionServerService();
}

@end
