//
//  IScreenRecorder.h
//  OSXRDP
//
//  Created by byungho on 4/22/26.
//

#ifndef IScreenRecorderImpl_h
#define IScreenRecorderImpl_h

#import <Foundation/Foundation.h>

typedef void (*on_record_data)(void* pixelBuffer, const CGRect* dirtyRects, int dirtyRectsCnt, void* userData, int displayIdx);
typedef void (*on_record_cmd)(int cmd, void* userData);

@protocol IScreenRecorder<NSObject>

@required
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


#endif /* IScreenRecorderImpl_h */
