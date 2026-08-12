#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface AdvancedSettings : NSWindowController

@property (weak) IBOutlet NSSwitch* ShiftToOpenSwitch;
@property (weak) IBOutlet NSSwitch* NetworkPathSwitch;
@property (weak) IBOutlet NSSwitch* NewWindowWithHotKeySwitch;

- (IBAction) onCloseBtnClicked:(id)sender;

- (IBAction) onShiftToOpenNewWindowHelpBtnClicked:(id)sender;

- (IBAction) onSNetworkPathHelpBtnClicked:(id)sender;

- (IBAction) onNewWindowWithHotKeyHelpBtnClicked:(id)sender;


@end

NS_ASSUME_NONNULL_END
