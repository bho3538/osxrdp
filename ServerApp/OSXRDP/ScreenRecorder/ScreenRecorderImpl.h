#import "IScreenRecorder.h"
#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

NS_ASSUME_NONNULL_BEGIN


@interface ScreenRecorderImpl : NSObject<SCStreamOutput, SCStreamDelegate, IScreenRecorder>

- (void)initializeWithDisplayId:(int)displayId
            DisplayIndex:(int)displayIdx
            RecordWidth:(int)width
            RecordHeight:(int)height
            RecordFramerate:(int)framerate
            RecordFormat:(int)recordFormat
            RecordDataCallback:(on_record_data)recordCb
            RecordDataCallbackUserData:(void*)userData
            RecordCmdCallback:(on_record_cmd)recordCmdCb
            RecordCmdCallbackUserData:(void*)userData2;
- (BOOL)start;
- (BOOL)stop;

@end

NS_ASSUME_NONNULL_END
