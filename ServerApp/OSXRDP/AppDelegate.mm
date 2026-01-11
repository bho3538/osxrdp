#import "AppDelegate.h"

#include "ipc.h"
#include "xstream.h"
#include "MirrorAppServer/MirrorAppServer.h"
#include "Utils/PermissionCheckUtils.h"
#include "Startup/StartupManager.h"

#import "UI/PermissionSettingsWindow.h"

@interface AppDelegate ()
{
    // UI
    // tray menu
    NSStatusItem* _trayMenu;
    
    // ETC
    MirrorAppServer* _server;
}

@property (strong) IBOutlet NSWindow *window;
@property (strong) PermissionSettingsWindow* permSettingsWindow;
@property (strong) IBOutlet NSTextField* aboutLinkLabel;
@property (strong) IBOutlet NSButton* startRemoteConnectionBtn;
@property (strong) IBOutlet NSSwitch* startupSwitch;

@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    // Insert code here to initialize your application
    [NSApp setActivationPolicy: NSApplicationActivationPolicyAccessory];
    
    // initialize UI code
    // create tray menu
    _trayMenu = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    
    // tray menu icon
    NSImage *img = [NSImage imageWithSystemSymbolName: @"bolt.horizontal.circle.fill" accessibilityDescription:@"OSXRDP menu logo"];
    _trayMenu.button.image = img;
    
    // tray menu list
    NSMenu* menus = [[NSMenu alloc] init];
    [menus addItemWithTitle:@"OSXRDP" action:nil keyEquivalent:@""];
    [menus addItem:NSMenuItem.separatorItem];
    [menus addItemWithTitle:@"Open" action:@selector(onOpenWindowMenuClicked) keyEquivalent:@""];
    [menus addItem:NSMenuItem.separatorItem];
    [menus addItemWithTitle:@"Close" action:@selector(onExitMenuClicked) keyEquivalent:@""];

    _trayMenu.menu = menus;
    
    // about link click event
    auto click = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(aboutUrlClicked:)];
    [self.aboutLinkLabel addGestureRecognizer:click];
    
    // start on login status
    if (StartupManager::IsStartupEnabled() == true) {
        [self.startupSwitch setState:NSControlStateValueOn];
    }
    
    // prepare osxrdp server
    [self startRemoteConnectionServer:YES];
}


- (void)applicationWillTerminate:(NSNotification *)aNotification {
    // Insert code here to tear down your application
    if (_server != nullptr) {
        _server->Stop();
    }
}


- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
    return NO;
}

- (void)onOpenWindowMenuClicked {
    [self.window makeKeyAndOrderFront:nil];
    
    // move window to front
    [self.window orderFrontRegardless];
}

- (void)onExitMenuClicked {
    if (_server != nullptr) {
        _server->Stop();
        
        delete _server;
        _server = nullptr;
    }
    
    [[NSApplication sharedApplication] terminate:nil];
}

- (IBAction)openPermissionWindowBtnClicked:(id)sender {
    self.permSettingsWindow = [[PermissionSettingsWindow alloc] initWithWindowNibName:@"PermissionSettingsWindow" ];
    
    NSWindow* settingsModalWindow = [self.permSettingsWindow window];
    
    [self.window beginSheet:settingsModalWindow completionHandler:^(NSModalResponse returnCode) {
        
    }];
}

- (IBAction)startRemoteConnectionBtnClicked:(id)sender {
    [self startRemoteConnectionServer:NO];
}

- (void)startRemoteConnectionServer:(bool)silent {
    if (PermissionCheckUtils::HasAllPermissionToStartRemoteConnection() == false) {
        if (silent == NO) {
            NSAlert* msg = [[NSAlert alloc] init];
            if (msg != nil)
            {
              [msg setMessageText:@"OSXRDP"];
              [msg setInformativeText: @"Please configure all permissions to start remote connection."];
              
              [msg runModal];
            }
        }
        return;
    }
    
    if (_server == nullptr) {
        _server = new MirrorAppServer();
        _server->Start();
        
        [self setEnabledBtnStyle: self.startRemoteConnectionBtn];
    }
}

- (void)stopRemoteConnectionServer {
    if (_server == nullptr) {
        return;
    }
    
    _server->Stop();
    delete _server;
    
    _server = nullptr;
    
    [self setDisabledBtnStyle: self.startRemoteConnectionBtn];
}


- (IBAction)aboutUrlClicked:(id)sender {
    NSURL* url = [NSURL URLWithString:@"https://github.com/bho3538/osxrdp"];
    
    [[NSWorkspace sharedWorkspace] openURL:url];
}

- (IBAction)onStartupChanged:(id)sender {
    
    bool isSwitchOn = self.startupSwitch.state == NSControlStateValueOn;
    
    if (isSwitchOn) {
        StartupManager::EnableStartup();
    }
    else {
        StartupManager::DisableStartup();
    }
    
}

- (void)setDisabledBtnStyle:(NSButton*)btn {
    if (btn == nil)
    {
      return;
    }
  
    [btn setTitle:@"Stopped"];
    [btn setBezelColor:[NSColor systemRedColor]];
}

- (void)setEnabledBtnStyle:(NSButton*)btn {
    if (btn == nil)
    {
      return;
    }
  
    [btn setTitle:@"Running"];
    [btn setBezelColor:[NSColor systemGreenColor]];
}


@end
