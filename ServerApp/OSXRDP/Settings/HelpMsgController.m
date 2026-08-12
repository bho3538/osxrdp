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
}

@end
