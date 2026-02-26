#import "MainViewController.h"

#include "../../RemoteConnection/RemoteConnectionService.h"
#include "../../Startup/StartupManager.h"
#include "../../Utils/PermissionCheckUtils.h"

#import "../PermissionSettingsWindow.h"

@interface MainViewController ()

@property (strong) PermissionSettingsWindow* permSettingsWindow;
@property (strong) IBOutlet NSTextField* aboutLinkLabel;
@property (strong) IBOutlet NSButton* startRemoteConnectionBtn;
@property (strong) IBOutlet NSTextField* startupLabel;
@property (strong) IBOutlet NSSwitch* startupSwitch;
@property (assign) BOOL didConfigureInitialState;

@end

@implementation MainViewController

- (void)configureInitialState {
    if (self.didConfigureInitialState == YES) {
        return;
    }

    self.didConfigureInitialState = YES;

    NSClickGestureRecognizer* click = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(aboutUrlClicked:)];
    [self.aboutLinkLabel addGestureRecognizer:click];

    if (StartupManager::IsMacOS13OrHigher() == true) {
        if (StartupManager::IsStartupEnabled() == true) {
            [self.startupSwitch setState:NSControlStateValueOn];
        }
    } else {
        self.startupLabel.hidden = YES;
        self.startupSwitch.hidden = YES;
    }

    [self setDisabledBtnStyle:self.startRemoteConnectionBtn];
    [self startRemoteConnectionServer:YES];
}

- (IBAction)openPermissionWindowBtnClicked:(id)sender {
    self.permSettingsWindow = [[PermissionSettingsWindow alloc] initWithWindowNibName:@"PermissionSettingsWindow"];

    NSWindow* settingsModalWindow = [self.permSettingsWindow window];
    [self.view.window beginSheet:settingsModalWindow completionHandler:^(NSModalResponse returnCode) {
    }];
}

- (IBAction)startRemoteConnectionBtnClicked:(id)sender {
    [self startRemoteConnectionServer:NO];
}

- (void)startRemoteConnectionServer:(BOOL)silent {
    if (PermissionCheckUtils::HasAllPermissionToStartRemoteConnection() == false) {
        if (silent == NO) {
            NSAlert* msg = [[NSAlert alloc] init];
            if (msg != nil) {
                [msg setMessageText:NSLocalizedString(@"main.alert.title", nil)];
                [msg setInformativeText:NSLocalizedString(@"main.alert.permission_required", nil)];
                [msg runModal];
            }
        }
        return;
    }

    bool didStart = StartRemoteConnectionServerService();
    if (didStart == true || IsRemoteConnectionServerServiceRunning() == true) {
        [self setEnabledBtnStyle:self.startRemoteConnectionBtn];
    }
}

- (void)stopRemoteConnectionServer {
    StopRemoteConnectionServerService();
    [self setDisabledBtnStyle:self.startRemoteConnectionBtn];
}

- (IBAction)aboutUrlClicked:(id)sender {
    NSURL* url = [NSURL URLWithString:@"https://github.com/bho3538/osxrdp"];
    [[NSWorkspace sharedWorkspace] openURL:url];
}

- (IBAction)onStartupChanged:(id)sender {
    bool isSwitchOn = self.startupSwitch.state == NSControlStateValueOn;

    if (isSwitchOn) {
        StartupManager::EnableStartup();
    } else {
        StartupManager::DisableStartup();
    }
}

- (void)setDisabledBtnStyle:(NSButton*)btn {
    if (btn == nil) {
        return;
    }

    [btn setTitle:NSLocalizedString(@"main.button.stopped", nil)];
    [btn setBezelColor:[NSColor systemRedColor]];
}

- (void)setEnabledBtnStyle:(NSButton*)btn {
    if (btn == nil) {
        return;
    }

    [btn setTitle:NSLocalizedString(@"main.button.running", nil)];
    [btn setBezelColor:[NSColor systemGreenColor]];
}

@end
