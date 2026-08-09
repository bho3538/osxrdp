#import "AudioOutputMuter.h"
#import <CoreAudio/CoreAudio.h>

// Virtual main volume selector; its home header (AudioHardwareService.h) is
// deprecated but the selector itself still works through AudioObject APIs
static const AudioObjectPropertySelector kOsxrdpVirtualMainVolumeSelector = 'vmvc';

static AudioObjectPropertyAddress DefaultOutputAddress(void) {
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    return address;
}

static AudioObjectPropertyAddress MuteAddress(void) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyMute,
        kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };
    return address;
}

static AudioObjectPropertyAddress VirtualVolumeAddress(void) {
    AudioObjectPropertyAddress address = {
        kOsxrdpVirtualMainVolumeSelector,
        kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };
    return address;
}

static bool HasSettableProperty(AudioObjectID objectId, AudioObjectPropertyAddress address) {
    Boolean settable = false;
    return AudioObjectHasProperty(objectId, &address) &&
           AudioObjectIsPropertySettable(objectId, &address, &settable) == noErr &&
           settable;
}

static bool GetUInt32Property(AudioObjectID objectId, AudioObjectPropertyAddress address, UInt32* value) {
    UInt32 size = sizeof(UInt32);
    return AudioObjectHasProperty(objectId, &address) &&
           AudioObjectGetPropertyData(objectId, &address, 0, NULL, &size, value) == noErr;
}

static bool SetUInt32Property(AudioObjectID objectId, AudioObjectPropertyAddress address, UInt32 value) {
    return HasSettableProperty(objectId, address) &&
           AudioObjectSetPropertyData(objectId, &address, 0, NULL, sizeof(UInt32), &value) == noErr;
}

static bool GetFloat32Property(AudioObjectID objectId, AudioObjectPropertyAddress address, Float32* value) {
    UInt32 size = sizeof(Float32);
    return AudioObjectHasProperty(objectId, &address) &&
           AudioObjectGetPropertyData(objectId, &address, 0, NULL, &size, value) == noErr;
}

static bool SetFloat32Property(AudioObjectID objectId, AudioObjectPropertyAddress address, Float32 value) {
    return HasSettableProperty(objectId, address) &&
           AudioObjectSetPropertyData(objectId, &address, 0, NULL, sizeof(Float32), &value) == noErr;
}

@implementation AudioOutputMuter {
    // Every state access and CoreAudio listener runs on this serial queue
    dispatch_queue_t _queue;
    BOOL _active;
    AudioObjectPropertyListenerBlock _defaultDeviceListener;
    NSMutableDictionary<NSNumber*, NSNumber*>* _savedMuteByDevice;
    NSMutableDictionary<NSNumber*, NSNumber*>* _savedVolumeByDevice;
    NSMutableDictionary<NSNumber*, id>* _muteListenerByDevice;
    NSMutableDictionary<NSNumber*, id>* _volumeListenerByDevice;
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _queue = dispatch_queue_create("osxrdp.audiomuter", DISPATCH_QUEUE_SERIAL);
        _savedMuteByDevice = [NSMutableDictionary dictionary];
        _savedVolumeByDevice = [NSMutableDictionary dictionary];
        _muteListenerByDevice = [NSMutableDictionary dictionary];
        _volumeListenerByDevice = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)mute {
    dispatch_async(_queue, ^{
        if (self->_active) {
            return;
        }
        self->_active = YES;

        // Listener first so a device switch during the apply is not missed
        [self installDefaultDeviceListener];
        [self applyToDevice:[AudioOutputMuter defaultOutputDevice]];
    });
}

- (void)restore {
    dispatch_sync(_queue, ^{
        if (self->_active == NO) {
            return;
        }
        self->_active = NO;

        [self removeDefaultDeviceListener];
        [self restoreAllDevices];
    });
}

+ (AudioDeviceID)defaultOutputDevice {
    AudioDeviceID deviceId = kAudioObjectUnknown;
    UInt32 size = sizeof(deviceId);
    AudioObjectPropertyAddress address = DefaultOutputAddress();
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &deviceId);
    return deviceId;
}

- (void)applyToDevice:(AudioDeviceID)deviceId {
    if (deviceId == kAudioObjectUnknown) {
        return;
    }

    NSNumber* key = [NSNumber numberWithUnsignedInt:deviceId];

    UInt32 muted = 0;
    if (HasSettableProperty(deviceId, MuteAddress()) && GetUInt32Property(deviceId, MuteAddress(), &muted)) {
        if ([_savedMuteByDevice objectForKey:key] == nil) {
            [_savedMuteByDevice setObject:[NSNumber numberWithUnsignedInt:muted] forKey:key];
        }
        // Listener first so an unmute during the apply is not missed
        [self installMuteListenerForDevice:deviceId];
        if (muted == 0) {
            SetUInt32Property(deviceId, MuteAddress(), 1);
        }
        return;
    }

    // Devices without a mute control: drop the virtual main volume instead
    Float32 volume = 0;
    if (HasSettableProperty(deviceId, VirtualVolumeAddress()) && GetFloat32Property(deviceId, VirtualVolumeAddress(), &volume)) {
        if ([_savedVolumeByDevice objectForKey:key] == nil) {
            [_savedVolumeByDevice setObject:[NSNumber numberWithFloat:volume] forKey:key];
        }
        [self installVolumeListenerForDevice:deviceId];
        SetFloat32Property(deviceId, VirtualVolumeAddress(), 0.0f);
        return;
    }

    // HDMI/DisplayPort outputs typically expose no software control at all
    NSLog(@"[AudioOutputMuter] output device %u has no mute or volume control", (unsigned int)deviceId);
}

- (void)installMuteListenerForDevice:(AudioDeviceID)deviceId {
    NSNumber* key = [NSNumber numberWithUnsignedInt:deviceId];
    if ([_muteListenerByDevice objectForKey:key] != nil) {
        return;
    }

    __weak AudioOutputMuter* weakSelf = self;
    AudioObjectPropertyListenerBlock listener = ^(UInt32 addressCount, const AudioObjectPropertyAddress* addresses) {
        (void)addressCount;
        (void)addresses;

        AudioOutputMuter* strongSelf = weakSelf; // delivered on _queue
        if (strongSelf == nil || strongSelf->_active == NO) {
            return;
        }

        // Re-assert mute when another client (volume keys etc.) cleared it;
        // reading first keeps our own set from looping
        UInt32 muted = 1;
        if (GetUInt32Property(deviceId, MuteAddress(), &muted) && muted == 0) {
            SetUInt32Property(deviceId, MuteAddress(), 1);
        }
    };

    AudioObjectPropertyAddress address = MuteAddress();
    if (AudioObjectAddPropertyListenerBlock(deviceId, &address, _queue, listener) == noErr) {
        [_muteListenerByDevice setObject:listener forKey:key];
    }
}

- (void)installVolumeListenerForDevice:(AudioDeviceID)deviceId {
    NSNumber* key = [NSNumber numberWithUnsignedInt:deviceId];
    if ([_volumeListenerByDevice objectForKey:key] != nil) {
        return;
    }

    __weak AudioOutputMuter* weakSelf = self;
    AudioObjectPropertyListenerBlock listener = ^(UInt32 addressCount, const AudioObjectPropertyAddress* addresses) {
        (void)addressCount;
        (void)addresses;

        AudioOutputMuter* strongSelf = weakSelf; // delivered on _queue
        if (strongSelf == nil || strongSelf->_active == NO) {
            return;
        }

        // Re-assert silence when another client raised the volume
        Float32 volume = 0;
        if (GetFloat32Property(deviceId, VirtualVolumeAddress(), &volume) && volume > 0.0f) {
            SetFloat32Property(deviceId, VirtualVolumeAddress(), 0.0f);
        }
    };

    AudioObjectPropertyAddress address = VirtualVolumeAddress();
    if (AudioObjectAddPropertyListenerBlock(deviceId, &address, _queue, listener) == noErr) {
        [_volumeListenerByDevice setObject:listener forKey:key];
    }
}

- (void)installDefaultDeviceListener {
    if (_defaultDeviceListener != nil) {
        return;
    }

    __weak AudioOutputMuter* weakSelf = self;
    AudioObjectPropertyListenerBlock listener = ^(UInt32 addressCount, const AudioObjectPropertyAddress* addresses) {
        AudioOutputMuter* strongSelf = weakSelf; // delivered on _queue
        if (strongSelf == nil || strongSelf->_active == NO) {
            return;
        }

        for (UInt32 i = 0; i < addressCount; i++) {
            if (addresses[i].mSelector == kAudioHardwarePropertyDefaultOutputDevice) {
                [strongSelf applyToDevice:[AudioOutputMuter defaultOutputDevice]];
                break;
            }
        }
    };

    AudioObjectPropertyAddress address = DefaultOutputAddress();
    if (AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &address, _queue, listener) == noErr) {
        _defaultDeviceListener = listener;
    }
}

- (void)removeDefaultDeviceListener {
    if (_defaultDeviceListener == nil) {
        return;
    }

    AudioObjectPropertyAddress address = DefaultOutputAddress();
    AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &address, _queue, _defaultDeviceListener);
    _defaultDeviceListener = nil;
}

- (void)restoreAllDevices {
    AudioObjectPropertyAddress muteAddress = MuteAddress();
    for (NSNumber* key in _muteListenerByDevice) {
        AudioObjectRemovePropertyListenerBlock((AudioDeviceID)[key unsignedIntValue], &muteAddress, _queue,
                                               [_muteListenerByDevice objectForKey:key]);
    }
    [_muteListenerByDevice removeAllObjects];

    AudioObjectPropertyAddress volumeAddress = VirtualVolumeAddress();
    for (NSNumber* key in _volumeListenerByDevice) {
        AudioObjectRemovePropertyListenerBlock((AudioDeviceID)[key unsignedIntValue], &volumeAddress, _queue,
                                               [_volumeListenerByDevice objectForKey:key]);
    }
    [_volumeListenerByDevice removeAllObjects];

    // A device that disappeared meanwhile fails the property call harmlessly
    for (NSNumber* key in _savedMuteByDevice) {
        SetUInt32Property((AudioDeviceID)[key unsignedIntValue], muteAddress,
                          [[_savedMuteByDevice objectForKey:key] unsignedIntValue]);
    }
    [_savedMuteByDevice removeAllObjects];

    for (NSNumber* key in _savedVolumeByDevice) {
        SetFloat32Property((AudioDeviceID)[key unsignedIntValue], VirtualVolumeAddress(),
                           [[_savedVolumeByDevice objectForKey:key] floatValue]);
    }
    [_savedVolumeByDevice removeAllObjects];
}

@end
