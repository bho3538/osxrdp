
#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <IOSurface/IOSurfaceRef.h>

typedef void (*on_record_data_fb)(void* pixelBuffer, const CGRect* dirtyRects, int dirtyRectsCnt, void* userData);
typedef void (*on_record_cmd)(int cmd, void* userData);

@interface ScreenRecorderFallbackImpl : NSObject

- (void)initializeWithDisplay:(SCDisplay*)display
            RecordWidth:(int)width
            RecordHeight:(int)height
            RecordFramerate:(int)framerate
            RecordFormat:(int)recordFormat
            RecordDataCallback:(on_record_data_fb)recordCb
            RecordDataCallbackUserData:(void*)userData
            RecordCmdCallback:(on_record_cmd)recordCmdCb
            RecordCmdCallbackUserData:(void*)userData2;

- (BOOL)start;

- (BOOL)stop;

@end
