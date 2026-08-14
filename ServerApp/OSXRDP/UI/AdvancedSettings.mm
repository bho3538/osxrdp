#import "AdvancedSettings.h"

#import "HelpMsgController.h"
#import "../Settings/ConfigManager.h"

@interface AdvancedSettings ()

@property (strong) IBOutlet NSSwitch* DynamicResolutionSwitch;
@property (strong) IBOutlet NSSwitch* AudioSwitch;
@property (strong) IBOutlet NSTextField* DynamicResolutionLabel;
@property (strong) IBOutlet NSTextField* AudioLabel;
@property (strong) IBOutlet NSButton* SaveBtn;

@end

@implementation AdvancedSettings

- (void) windowDidLoad {
    [super windowDidLoad];

    // translate
    self.window.title = NSLocalizedString(@"advanced.window.title", nil);
    self.DynamicResolutionLabel.stringValue = NSLocalizedString(@"advanced.label.dynamic_resolution", nil);
    self.AudioLabel.stringValue = NSLocalizedString(@"advanced.label.audio", nil);
    [self.SaveBtn setTitle:NSLocalizedString(@"advanced.button.save", nil)];

    // load user settings
    if (_CONFIG_ENABLED(_ENABLE_DYNAMIC_RESOLUTION) == true) {
        self.DynamicResolutionSwitch.state = NSControlStateValueOn;
    }
    else {
        self.DynamicResolutionSwitch.state = NSControlStateValueOff;
    }
    
    if (_CONFIG_ENABLED(_ENABLE_AUDIO) == true) {
        self.AudioSwitch.state = NSControlStateValueOn;
    }
    else {
        self.AudioSwitch.state = NSControlStateValueOff;
    }
}

- (IBAction) onCloseBtnClicked:(id)sender {
    if (self.DynamicResolutionSwitch.state == NSControlStateValueOn) {
        ConfigManager::Instance()->SetBooleanValue(_ENABLE_DYNAMIC_RESOLUTION, YES);
    }
    else {
        ConfigManager::Instance()->SetBooleanValue(_ENABLE_DYNAMIC_RESOLUTION, NO);
    }
    
    if (self.AudioSwitch.state == NSControlStateValueOn) {
        ConfigManager::Instance()->SetBooleanValue(_ENABLE_AUDIO, YES);
    }
    else {
        ConfigManager::Instance()->SetBooleanValue(_ENABLE_AUDIO, NO);
    }
    
    [self close];
}

- (IBAction) onDynamicResolutionHelpBtnClicked:(id)sender {
    if (sender == nil) {
        return;
    }

    NSButton* btn = reinterpret_cast<NSButton*>(sender);

    HelpMsgController* view = [[HelpMsgController alloc] initWithHelpMsg:NSLocalizedString(@"advanced.help.dynamic_resolution", nil)];
    
    NSPopover* popover = [[NSPopover alloc] init];
    popover.behavior = NSPopoverBehaviorTransient;
    popover.contentViewController = view;
    [popover showRelativeToRect: btn.bounds ofView:btn preferredEdge:NSMinYEdge];
}

- (IBAction) onAudioHelpBtnClicked:(id)sender {
    if (sender == nil) {
        return;
    }

    NSButton* btn = reinterpret_cast<NSButton*>(sender);

    HelpMsgController* view = [[HelpMsgController alloc] initWithHelpMsg:NSLocalizedString(@"advanced.help.audio", nil)];
    
    NSPopover* popover = [[NSPopover alloc] init];
    popover.behavior = NSPopoverBehaviorTransient;
    popover.contentViewController = view;
    [popover showRelativeToRect: btn.bounds ofView:btn preferredEdge:NSMinYEdge];
}

@end
