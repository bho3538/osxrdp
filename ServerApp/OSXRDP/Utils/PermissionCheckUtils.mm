
#include "PermissionCheckUtils.h"
#include <CoreGraphics/CoreGraphics.h>
#include <ApplicationServices/ApplicationServices.h>

bool PermissionCheckUtils::HasAccPermission() {
    return AXIsProcessTrustedWithOptions(nullptr) != 0 ? true : false;
}

bool PermissionCheckUtils::HasScreenRecordPermission() {
    return CGPreflightScreenCaptureAccess();
}

void PermissionCheckUtils::ShowAccPermissionRequestDialog() {
    CFDictionaryRef options = ::CFDictionaryCreate(
      kCFAllocatorDefault,
      (const void**)&kAXTrustedCheckOptionPrompt,
      (const void**)&kCFBooleanTrue,
      1,
      &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks
    );
    
    if (options == NULL)
    {
      return;
    }
    
    AXIsProcessTrustedWithOptions(options);
    
    CFRelease(options);
}

void PermissionCheckUtils::ShowScreenRecordPermissionRequestDialog() {
    CGRequestScreenCaptureAccess();
}

void PermissionCheckUtils::ResetAccPermission() {
    NSTask* task = [[NSTask alloc] init];

    [task setLaunchPath:@"/usr/bin/tccutil"];
    [task setArguments:@[@"reset", @"Accessibility", @"com.byungho.osxrdp.mainapp"]];

    @try
    {
      [task launch];
      [task waitUntilExit];
    }
    @catch (NSException* exception)
    {
      return;
    }
}

void PermissionCheckUtils::ResetScreenRecordPermission() {
    NSTask* task = [[NSTask alloc] init];

    [task setLaunchPath:@"/usr/bin/tccutil"];
    [task setArguments:@[@"reset", @"ScreenCapture", @"com.byungho.osxrdp.mainapp"]];

    @try
    {
      [task launch];
      [task waitUntilExit];
    }
    @catch (NSException* exception)
    {
      return;
    }
}

bool PermissionCheckUtils::HasAllPermissionToStartRemoteConnection() {
    return HasAccPermission() && HasScreenRecordPermission();
}
