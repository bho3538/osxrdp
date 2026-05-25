#import "FileCopyWindow.h"

@interface FileCopyWindow ()

@property (strong) IBOutlet NSTextField* fileNameLabel;
@property (strong) IBOutlet NSTextField* statusLabel;
@property (strong) IBOutlet NSProgressIndicator* progressIndicator;
@property (strong) IBOutlet NSButton* cancelButton;

@end

@implementation FileCopyWindow

- (instancetype)init {
    return [super initWithWindowNibName:@"FileCopyWindow"];
}

- (void)windowDidLoad {
    [super windowDidLoad];

    NSWindow* window = [self window];
    [window setTitle:NSLocalizedString(@"filecopy.window.title", nil)];
    [window setReleasedWhenClosed:NO];
    [window center];

    [self.cancelButton setTitle:NSLocalizedString(@"filecopy.button.cancel", nil)];
    [self.fileNameLabel setStringValue:@""];
    [self.statusLabel setStringValue:@""];
    [self.progressIndicator setIndeterminate:NO];
    [self.progressIndicator setMinValue:0.0];
    [self.progressIndicator setMaxValue:100.0];
    [self.progressIndicator setDoubleValue:0.0];
}

- (void)showWindow {
    [[self window] center];
    [self showWindow:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)updateFileName:(NSString *)fileName transferredBytes:(unsigned long long)transferredBytes totalBytes:(unsigned long long)totalBytes {
    NSString* name = fileName != nil ? fileName : @"";
    [self.fileNameLabel setStringValue:name];

    double progress = 0.0;
    if (totalBytes > 0) {
        progress = ((double)transferredBytes / (double)totalBytes) * 100.0;
    }
    [self.progressIndicator setDoubleValue:progress];

    NSString* status = [NSString stringWithFormat:NSLocalizedString(@"filecopy.status.bytes", nil), transferredBytes, totalBytes];
    [self.statusLabel setStringValue:status];
}

- (void)closeWindow {
    [[self window] close];
}

- (IBAction)onCancelClicked:(id)sender {
    if (_cancelHandler != nil) {
        _cancelHandler();
    }
}

@end
