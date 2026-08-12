#import "AdvancedSettings.h"

#import "HelpMsgController.h"
#import "../Settings/ConfigManager.h"

@interface AdvancedSettings ()

@end

@implementation AdvancedSettings

- (void) windowDidLoad
{
    [super windowDidLoad];
    
    if (_CONFIG_ENABLED(_ENABLE_SHIFT_NEWWINDOW) == true)
    {
        self.ShiftToOpenSwitch.state = NSControlStateValueOn;
    }
    else
    {
        self.ShiftToOpenSwitch.state = NSControlStateValueOff;
    }
    
    if (ConfigManager::Instance()->GetBooleanValue(_ENABLE_NETWORK_PATH) == YES)
    {
        self.NetworkPathSwitch.state = NSControlStateValueOn;
    }
    else
    {
        self.NetworkPathSwitch.state = NSControlStateValueOff;
    }
    
    if (ConfigManager::Instance()->GetBooleanValue(_ENABLE_NEWWINDOW_LIKE_WINDOWS) == YES)
    {
        self.NewWindowWithHotKeySwitch.state = NSControlStateValueOn;
    }
    else
    {
        self.NewWindowWithHotKeySwitch.state = NSControlStateValueOff;
    }
}

- (IBAction) onCloseBtnClicked:(id)sender
{
    if (self.ShiftToOpenSwitch.state == NSControlStateValueOn)
    {
        ConfigManager::Instance()->SetBooleanValue(_ENABLE_SHIFT_NEWWINDOW, YES);
    }
    else
    {
        ConfigManager::Instance()->SetBooleanValue(_ENABLE_SHIFT_NEWWINDOW, NO);
    }
    
    if (self.NetworkPathSwitch.state == NSControlStateValueOn)
    {
        ConfigManager::Instance()->SetBooleanValue(_ENABLE_NETWORK_PATH, YES);
    }
    else
    {
        ConfigManager::Instance()->SetBooleanValue(_ENABLE_NETWORK_PATH, NO);
    }
    
    if (self.NewWindowWithHotKeySwitch.state == NSControlStateValueOn)
    {
        ConfigManager::Instance()->SetBooleanValue(_ENABLE_NEWWINDOW_LIKE_WINDOWS, YES);
    }
    else
    {
        ConfigManager::Instance()->SetBooleanValue(_ENABLE_NEWWINDOW_LIKE_WINDOWS, NO);
    }
    
    [self close];
}

- (IBAction) onShiftToOpenNewWindowHelpBtnClicked:(id)sender
{
    if (sender == nil)
    {
        return;
    }
    
    NSButton* btn = reinterpret_cast<NSButton*>(sender);
    
    HelpMsgController* view = [[HelpMsgController alloc] initWithHelpMsg:@"blah blah blah"];
    
    NSPopover* popover = [[NSPopover alloc] init];
    popover.behavior = NSPopoverBehaviorTransient;
    popover.contentViewController = view;
    [popover showRelativeToRect: btn.bounds ofView:btn preferredEdge:NSMinYEdge];
}

- (IBAction) onSNetworkPathHelpBtnClicked:(id)sender
{
    if (sender == nil)
    {
        return;
    }
    
    NSButton* btn = reinterpret_cast<NSButton*>(sender);
    
    HelpMsgController* view = [[HelpMsgController alloc] initWithHelpMsg:@"blah blah blah"];
    
    NSPopover* popover = [[NSPopover alloc] init];
    popover.behavior = NSPopoverBehaviorTransient;
    popover.contentViewController = view;
    [popover showRelativeToRect: btn.bounds ofView:btn preferredEdge:NSMinYEdge];
}

- (IBAction) onNewWindowWithHotKeyHelpBtnClicked:(id)sender
{
    if (sender == nil)
    {
        return;
    }
    
    NSButton* btn = reinterpret_cast<NSButton*>(sender);
    
    HelpMsgController* view = [[HelpMsgController alloc] initWithHelpMsg:@"blah blah blah"];
    
    NSPopover* popover = [[NSPopover alloc] init];
    popover.behavior = NSPopoverBehaviorTransient;
    popover.contentViewController = view;
    [popover showRelativeToRect: btn.bounds ofView:btn preferredEdge:NSMinYEdge];
}

@end
