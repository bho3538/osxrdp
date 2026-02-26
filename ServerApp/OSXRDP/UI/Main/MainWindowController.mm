#import "MainWindowController.h"

#import "MainViewController.h"

@interface MainWindowController ()

@property (strong) IBOutlet MainViewController* mainViewController;
@property (assign) BOOL didInitializeMainUI;

@end

@implementation MainWindowController

- (void)initializeMainUI {
    if (self.didInitializeMainUI == YES) {
        return;
    }

    self.didInitializeMainUI = YES;
    [self.mainViewController configureInitialState];
}

- (void)showMainWindow {
    [self initializeMainUI];

    [self.window makeKeyAndOrderFront:nil];
    [self.window orderFrontRegardless];
}

@end
