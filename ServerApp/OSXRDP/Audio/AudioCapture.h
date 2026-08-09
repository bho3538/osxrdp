#ifndef AudioCapture_h
#define AudioCapture_h

#import <Foundation/Foundation.h>

// Delivers interleaved 16-bit little-endian PCM frames at the configured
// sample rate and channel count
typedef void (*on_audio_pcm)(const void* pcmData, int dataLen, void* userData);

// Invoked once when the capture gave up restarting for good
typedef void (*on_audio_capture_giveup)(void* userData);

@interface AudioCapture : NSObject

- (instancetype)initWithSampleRate:(int)sampleRate
                      channelCount:(int)channelCount
                          callback:(on_audio_pcm)callback
                    giveUpCallback:(on_audio_capture_giveup)giveUpCallback
                  callbackUserData:(void*)userData;

// Returns NO when system audio capture is unavailable on this system
- (BOOL)start;
- (void)stop;

@end

#endif /* AudioCapture_h */
