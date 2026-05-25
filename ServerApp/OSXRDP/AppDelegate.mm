#import "AppDelegate.h"

#include <signal.h>
#include "RemoteConnection/RemoteConnectionService.h"

#import "UI/Main/MainWindowController.h"

void _handle_sigterm(int signal);

@interface AppDelegate ()
{
    NSStatusItem* _trayMenu;
    NSMenuItem* _saveCopiedFilesMenuItem;
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

    _saveCopiedFilesMenuItem = [menus addItemWithTitle:NSLocalizedString(@"statusbar.menu.save_copied_files", nil) action:@selector(onSaveCopiedFilesMenuClicked) keyEquivalent:@""];
    _saveCopiedFilesMenuItem.target = self;
    
    [menus addItem:NSMenuItem.separatorItem];
    
    NSMenuItem* closeItem = [menus addItemWithTitle:NSLocalizedString(@"statusbar.menu.close", nil) action:@selector(onExitMenuClicked) keyEquivalent:@""];
    closeItem.target = self;

    _trayMenu.menu = menus;
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if (menuItem == _saveCopiedFilesMenuItem) {
        return HasRemoteClipboardFiles();
    }

    return YES;
}

- (void)onOpenWindowMenuClicked {
    [NSApp activateIgnoringOtherApps:YES];
    [self.mainWindowController showMainWindow];
}

- (void)onExitMenuClicked {
    [NSApp activateIgnoringOtherApps:YES];

    NSAlert* alert = [[NSAlert alloc] init];
    if (alert == nil) {
        return;
    }

    [alert setMessageText:NSLocalizedString(@"statusbar.quit.confirm.title", nil)];
    [alert setInformativeText:NSLocalizedString(@"statusbar.quit.confirm.message", nil)];
    [alert setAlertStyle:NSAlertStyleWarning];
    NSButton* noButton = [alert addButtonWithTitle:NSLocalizedString(@"statusbar.quit.confirm.no", nil)];
    NSButton* yesButton = [alert addButtonWithTitle:NSLocalizedString(@"statusbar.quit.confirm.yes", nil)];
    [noButton setKeyEquivalent:@"\r"];
    [yesButton setKeyEquivalent:@""];

    if ([alert runModal] != NSAlertSecondButtonReturn) {
        return;
    }

    [[NSApplication sharedApplication] terminate:nil];
}

- (void)onSaveCopiedFilesMenuClicked {
    StartRemoteClipboardFileCopy();
}

void _handle_sigterm(int signal) {
    NSLog(@"[OSXRDP] on sigterm");
    StopRemoteConnectionServerService();
}

@end
