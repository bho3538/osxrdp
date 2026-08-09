#ifndef AudioOutputMuter_h
#define AudioOutputMuter_h

#import <Foundation/Foundation.h>

// Mutes the local default audio output while remote audio redirection is
// active and restores the previous state afterward. Follows default device
// changes and re-asserts mute when something unmutes the device.
@interface AudioOutputMuter : NSObject

- (void)mute;
- (void)restore;

@end

#endif /* AudioOutputMuter_h */
