#import "HelpMsgController.h"

@interface HelpMsgController ()

@property (strong) NSString* _msg;

@end

@implementation HelpMsgController

- (id) initWithHelpMsg:(NSString*)msg
{
    self = [super initWithNibName:@"HelpMsgController" bundle:nil];
    
    self._msg = msg;
    
    return self;
}

- (void) viewDidLoad
{
    [super viewDidLoad];
    // Do view setup here.
    
    [self.HelpMsg setStringValue: self._msg];

    NSRect frame = self.HelpMsg.frame;
    NSSize fitSize = [self.HelpMsg.cell cellSizeForBounds: NSMakeRect(0, 0, NSWidth(frame), CGFLOAT_MAX)];

    frame.size.height = fitSize.height;
    frame.origin.y = (NSHeight(self.view.bounds) - fitSize.height) / 2.0;

    self.HelpMsg.frame = frame;
    self.HelpMsg.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin | NSViewMaxYMargin;
}

@end
