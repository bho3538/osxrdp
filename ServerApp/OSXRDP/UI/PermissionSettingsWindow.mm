
#import "PermissionSettingsWindow.h"
#include "../Utils/PermissionCheckUtils.h"

@interface PermissionSettingsWindow ()

@property (strong) IBOutlet NSButton* accPermBtn;
@property (strong) IBOutlet NSButton* recordPermBtn;
@property (strong) IBOutlet NSTextField* accessibilityPermLabel;
@property (strong) IBOutlet NSTextField* screenRecordPermLabel;
@property (strong) IBOutlet NSButton* restartAppBtn;
@property (strong) IBOutlet NSButton* closeBtn;

@end

@implementation PermissionSettingsWindow

- (void)windowDidLoad {
    [super windowDidLoad];

    self.window.title = NSLocalizedString(@"permission.window.title", nil);
    self.accessibilityPermLabel.stringValue = NSLocalizedString(@"permission.label.accessibility", nil);
    self.screenRecordPermLabel.stringValue = NSLocalizedString(@"permission.label.screen_record", nil);
    [self.restartAppBtn setTitle:NSLocalizedString(@"permission.button.restart_app", nil)];
    [self.closeBtn setTitle:NSLocalizedString(@"permission.button.close", nil)];

    [self checkPermStatus];
}

- (void)checkPermStatus {
    if (PermissionCheckUtils::HasAccPermission() == true) {
        [self setEnabledBtnStyle: self.accPermBtn];
    }
    else {
        [self setDisabledBtnStyle: self.accPermBtn];
    }
    
    if (PermissionCheckUtils::HasScreenRecordPermission() == true) {
        [self setEnabledBtnStyle: self.recordPermBtn];
    }
    else {
        [self setDisabledBtnStyle: self.recordPermBtn];
    }
}

- (IBAction)accPermBtnClicked:(id)sender {
    if (PermissionCheckUtils::HasAccPermission() == false) {
        PermissionCheckUtils::ResetAccPermission();
        PermissionCheckUtils::ShowAccPermissionRequestDialog();
    }
    else {
        // update btn color
        [self setEnabledBtnStyle: self.accPermBtn];
    }
}

- (IBAction)screenRecordBtnClicked:(id)sender {
    if (PermissionCheckUtils::HasScreenRecordPermission() == false) {
        PermissionCheckUtils::ResetScreenRecordPermission();
        PermissionCheckUtils::ShowScreenRecordPermissionRequestDialog();
    }
    else {
        // update btn color
        [self setEnabledBtnStyle: self.recordPermBtn];
    }
}

- (IBAction)restartAppBtnClicked:(id)sender {
    pid_t pid = getpid();
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];

    NSString *cmd = [NSString stringWithFormat:
        @"while kill -0 %d 2>/dev/null; do sleep 0.5; done; "
        "open -n '%@'",
        pid,
        [bundlePath stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]
    ];

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/bin/sh";
    task.arguments = @[@"-c", cmd];

    @try {
        [task launch];
    } @catch (NSException *e) {
        NSLog(@"Failed to spawn relaunch script: %@", e);
    }

    [self.window close];
    // terminate self
    [NSApp terminate:nil];
}

- (IBAction)closeBtnClicked:(id)sender {
    [self close];
}

- (void)setDisabledBtnStyle:(NSButton*)btn {
    if (btn == nil)
    {
      return;
    }
  
    [btn setTitle:NSLocalizedString(@"permission.button.refresh", nil)];
    [btn setBezelColor:[NSColor systemRedColor]];
}

- (void)setEnabledBtnStyle:(NSButton*)btn {
    if (btn == nil)
    {
      return;
    }
  
    [btn setTitle:NSLocalizedString(@"permission.button.ok", nil)];
    [btn setBezelColor:[NSColor systemGreenColor]];
}

@end
