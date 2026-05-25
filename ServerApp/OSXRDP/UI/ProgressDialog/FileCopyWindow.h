#import <Cocoa/Cocoa.h>

typedef void (^FileCopyCancelHandler)(void);

@interface FileCopyWindow : NSWindowController

@property (nonatomic, copy) FileCopyCancelHandler cancelHandler;

- (void)showWindow;
- (void)updateFileName:(NSString *)fileName transferredBytes:(unsigned long long)transferredBytes totalBytes:(unsigned long long)totalBytes;
- (void)closeWindow;

@end
