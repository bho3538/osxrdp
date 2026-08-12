#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface HelpMsgController : NSViewController

- (id) initWithHelpMsg:(NSString*)msg;

@property (weak) IBOutlet NSTextField* HelpMsg;

@end

NS_ASSUME_NONNULL_END
