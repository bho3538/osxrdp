#import "AudioCapture.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>

// SCStream requires a video configuration even when only audio is captured
static const int AUDIO_STREAM_FRAME_SIZE = 64;
static const int GET_DISPLAY_TIMEOUT_SEC = 5;

// The captured display can disappear while the session reconfigures the
// virtual monitors; retry until the display list settles again
static const int RESTART_DELAY_SEC = 2;
static const int MAX_RESTART_ATTEMPTS = 15;

@interface AudioCapture () <SCStreamOutput, SCStreamDelegate>
@end

@implementation AudioCapture {
    int _sampleRate;
    int _channelCount;
    on_audio_pcm _callback;
    on_audio_capture_giveup _giveUpCallback;
    void* _callbackUserData;

    dispatch_queue_t _audioQueue;
    // Serializes every start/retry attempt so two attempts never interleave
    dispatch_queue_t _startQueue;
    SCStream* _stream;

    int16_t* _convertBuffer;
    int _convertBufferFrames;
    BOOL _formatWarned;

    BOOL _stopRequested;
    int _restartAttempts;
}

- (instancetype)initWithSampleRate:(int)sampleRate
                      channelCount:(int)channelCount
                          callback:(on_audio_pcm)callback
                    giveUpCallback:(on_audio_capture_giveup)giveUpCallback
                  callbackUserData:(void*)userData {
    self = [super init];
    if (self != nil) {
        _sampleRate = sampleRate;
        _channelCount = channelCount;
        _callback = callback;
        _giveUpCallback = giveUpCallback;
        _callbackUserData = userData;

        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, -1);
        _audioQueue = dispatch_queue_create("osxrdp.audiocapture", attr);

        dispatch_queue_attr_t startAttr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        _startQueue = dispatch_queue_create("osxrdp.audiocapture.start", startAttr);
    }
    return self;
}

- (void)dealloc {
    if (_convertBuffer != NULL) {
        free(_convertBuffer);
        _convertBuffer = NULL;
    }
}

- (SCDisplay*)getAnyDisplay API_AVAILABLE(macos(13.0)) {
    __block SCDisplay* display = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent* content, NSError* error) {
        if (error == nil) {
            display = [[content displays] firstObject];
        }
        dispatch_semaphore_signal(semaphore);
    }];

    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)GET_DISPLAY_TIMEOUT_SEC * NSEC_PER_SEC));
    return display;
}

- (BOOL)start {
    if (@available(macOS 13.0, *)) {
        @synchronized (self) {
            _stopRequested = NO;
            _restartAttempts = 0;
        }

        // Attempts run on the serial start queue so they never interleave
        // and never block the caller's thread
        dispatch_async(_startQueue, ^{
            if (@available(macOS 13.0, *)) {
                if ([self tryStart] == NO) {
                    [self scheduleRestart];
                }
            }
        });
        return YES;
    }

    return NO;
}

- (SCStream*)buildStream API_AVAILABLE(macos(13.0)) {
    SCDisplay* display = [self getAnyDisplay];
    if (display == nil) {
        NSLog(@"[AudioCapture] no display available for the capture stream");
        return nil;
    }

    SCContentFilter* filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
    SCStreamConfiguration* config = [[SCStreamConfiguration alloc] init];
    config.capturesAudio = YES;
    config.excludesCurrentProcessAudio = YES;
    config.sampleRate = _sampleRate;
    config.channelCount = _channelCount;
    config.width = AUDIO_STREAM_FRAME_SIZE;
    config.height = AUDIO_STREAM_FRAME_SIZE;
    config.minimumFrameInterval = CMTimeMake(1, 1);
    config.showsCursor = NO;

    SCStream* stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];

    NSError* error = nil;
    if ([stream addStreamOutput:self type:SCStreamOutputTypeAudio sampleHandlerQueue:_audioQueue error:&error] == NO) {
        NSLog(@"[AudioCapture] addStreamOutput failed: %@", error);
        return nil;
    }

    return stream;
}

- (BOOL)tryStart API_AVAILABLE(macos(13.0)) {
    @synchronized (self) {
        if (_stopRequested || _stream != nil) {
            return YES;
        }
    }

    SCStream* stream = [self buildStream];
    if (stream == nil) {
        return NO;
    }

    __block NSError* startError = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [stream startCaptureWithCompletionHandler:^(NSError* completionError) {
        startError = completionError;
        dispatch_semaphore_signal(semaphore);
    }];
    long waitResult = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)GET_DISPLAY_TIMEOUT_SEC * NSEC_PER_SEC));

    NSError* removeError = nil;
    if (startError != nil || waitResult != 0) {
        NSLog(@"[AudioCapture] startCapture failed: %@", startError != nil ? (id)startError : @"timeout");
        [stream removeStreamOutput:self type:SCStreamOutputTypeAudio error:&removeError];
        return NO;
    }

    @synchronized (self) {
        if (_stopRequested) {
            // stop() ran while this attempt was in flight; tear down
            [stream stopCaptureWithCompletionHandler:^(NSError* stopError) {}];
            [stream removeStreamOutput:self type:SCStreamOutputTypeAudio error:&removeError];
            return NO;
        }
        _stream = stream;
        _restartAttempts = 0;
    }

    NSLog(@"[AudioCapture] capture stream running");
    return YES;
}

- (void)scheduleRestart {
    @synchronized (self) {
        if (_stopRequested) {
            return;
        }
        if (_restartAttempts >= MAX_RESTART_ATTEMPTS) {
            NSLog(@"[AudioCapture] giving up capture restart after %d attempts", _restartAttempts);
            // Deliver on the audio queue so stop()'s drain covers this too
            dispatch_async(_audioQueue, ^{
                if (self->_giveUpCallback != NULL) {
                    self->_giveUpCallback(self->_callbackUserData);
                }
            });
            return;
        }
        _restartAttempts++;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)RESTART_DELAY_SEC * NSEC_PER_SEC), _startQueue, ^{
        if (@available(macOS 13.0, *)) {
            if ([self tryStart] == NO) {
                [self scheduleRestart];
            }
        }
    });
}

- (void)stop {
    if (@available(macOS 13.0, *)) {
        SCStream* stream = nil;
        @synchronized (self) {
            _stopRequested = YES;
            stream = _stream;
            _stream = nil;
        }

        if (stream != nil) {
            dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
            [stream stopCaptureWithCompletionHandler:^(NSError* error) {
                dispatch_semaphore_signal(semaphore);
            }];
            dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)GET_DISPLAY_TIMEOUT_SEC * NSEC_PER_SEC));

            NSError* error = nil;
            [stream removeStreamOutput:self type:SCStreamOutputTypeAudio error:&error];
        }

        // Drain an in-flight audio callback and clear the consumer on the
        // audio queue itself so a late buffer can never reach a freed consumer
        dispatch_sync(_audioQueue, ^{
            self->_callback = NULL;
            self->_giveUpCallback = NULL;
            self->_callbackUserData = NULL;
        });
    }
}

- (void)stream:(SCStream*)stream didStopWithError:(NSError*)error {
    NSLog(@"[AudioCapture] stream stopped: %@", error);

    @synchronized (self) {
        // Ignore notifications for replaced or never-registered streams so a
        // failed attempt cannot spawn a duplicate restart chain
        if (_stopRequested || stream != _stream) {
            return;
        }
        _stream = nil;
    }

    // The display list changes while the session reconfigures monitors;
    // rebuild the capture stream once it settles
    [self scheduleRestart];
}

- (void)stream:(SCStream*)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (@available(macOS 13.0, *)) {
        if (type != SCStreamOutputTypeAudio || _callback == NULL) {
            return;
        }
        if (CMSampleBufferDataIsReady(sampleBuffer) == NO) {
            return;
        }

        CMAudioFormatDescriptionRef formatDesc = (CMAudioFormatDescriptionRef)CMSampleBufferGetFormatDescription(sampleBuffer);
        const AudioStreamBasicDescription* asbd = formatDesc != NULL ? CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) : NULL;
        if (asbd == NULL ||
            (asbd->mFormatFlags & kAudioFormatFlagIsFloat) == 0 ||
            asbd->mBitsPerChannel != 32 ||
            (int)asbd->mSampleRate != _sampleRate) {
            // Streaming at a mislabeled rate would play at the wrong speed,
            // so drop the buffers and leave a diagnostic instead
            if (_formatWarned == NO) {
                _formatWarned = YES;
                NSLog(@"[AudioCapture] unsupported sample format, flags=0x%X bits=%d rate=%d",
                      asbd != NULL ? (unsigned int)asbd->mFormatFlags : 0,
                      asbd != NULL ? (int)asbd->mBitsPerChannel : 0,
                      asbd != NULL ? (int)asbd->mSampleRate : 0);
            }
            return;
        }

        int frames = (int)CMSampleBufferGetNumSamples(sampleBuffer);
        if (frames <= 0) {
            return;
        }

        size_t ablSize = 0;
        if (CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, &ablSize, NULL, 0, NULL, NULL, 0, NULL) != kCMBlockBufferNoErr || ablSize == 0) {
            return;
        }

        AudioBufferList* abl = (AudioBufferList*)malloc(ablSize);
        if (abl == NULL) {
            return;
        }

        CMBlockBufferRef blockBuffer = NULL;
        OSStatus status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, NULL, abl, ablSize,
                                                                                 kCFAllocatorDefault, kCFAllocatorDefault,
                                                                                 0, &blockBuffer);
        if (status != kCMBlockBufferNoErr) {
            free(abl);
            return;
        }

        [self convertAndDeliver:abl
                         frames:frames
                 sourceChannels:(int)asbd->mChannelsPerFrame
                 nonInterleaved:(asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0];

        if (blockBuffer != NULL) {
            CFRelease(blockBuffer);
        }
        free(abl);
    }
}

- (void)convertAndDeliver:(const AudioBufferList*)abl frames:(int)frames sourceChannels:(int)sourceChannels nonInterleaved:(BOOL)nonInterleaved {
    on_audio_pcm callback = _callback;
    void* callbackUserData = _callbackUserData;
    if (callback == NULL) {
        return;
    }

    if (_convertBufferFrames < frames) {
        int16_t* grown = (int16_t*)realloc(_convertBuffer, (size_t)frames * _channelCount * sizeof(int16_t));
        if (grown == NULL) {
            return;
        }
        _convertBuffer = grown;
        _convertBufferFrames = frames;
    }

    if (nonInterleaved) {
        int sourceBuffers = (int)abl->mNumberBuffers;
        for (int ch = 0; ch < _channelCount; ch++) {
            // Duplicate the last source channel when fewer channels arrive
            int sourceCh = ch < sourceBuffers ? ch : sourceBuffers - 1;
            if (sourceCh < 0) {
                return;
            }

            const float* source = (const float*)abl->mBuffers[sourceCh].mData;
            int available = (int)(abl->mBuffers[sourceCh].mDataByteSize / sizeof(float));
            for (int i = 0; i < frames; i++) {
                float value = i < available ? source[i] : 0.0f;
                _convertBuffer[i * _channelCount + ch] = [AudioCapture clampSample:value];
            }
        }
    } else {
        if (sourceChannels <= 0) {
            return;
        }

        const float* source = (const float*)abl->mBuffers[0].mData;
        int available = (int)(abl->mBuffers[0].mDataByteSize / sizeof(float));
        for (int i = 0; i < frames; i++) {
            for (int ch = 0; ch < _channelCount; ch++) {
                // Duplicate the last source channel when fewer channels arrive
                int sourceCh = ch < sourceChannels ? ch : sourceChannels - 1;
                int sourceIndex = i * sourceChannels + sourceCh;
                float value = sourceIndex < available ? source[sourceIndex] : 0.0f;
                _convertBuffer[i * _channelCount + ch] = [AudioCapture clampSample:value];
            }
        }
    }

    callback(_convertBuffer, frames * _channelCount * (int)sizeof(int16_t), callbackUserData);
}

+ (int16_t)clampSample:(float)value {
    float scaled = value * 32767.0f;
    if (scaled > 32767.0f) {
        return 32767;
    }
    if (scaled < -32768.0f) {
        return -32768;
    }
    return (int16_t)scaled;
}

@end
