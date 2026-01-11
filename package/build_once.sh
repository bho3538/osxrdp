#!/bin/bash

# build osxup
cd ..

xcodebuild build -scheme osxup -configuration Release \
  -destination "generic/platform=macOS" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  BUILD_DIR=/tmp/build_arm64

xcodebuild build -scheme osxup -configuration Release \
  -destination "generic/platform=macOS" \
  ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO \
  BUILD_DIR=/tmp/build_x86_64

lipo -create \
  /tmp/build_arm64/Release/libosxup.dylib \
  /tmp/build_x86_64/Release/libosxup.dylib \
  -output /tmp/libosxup.dylib

codesign --force --sign "Developer ID Application: BYEONGHO KIM (33X7M69J4B)" \
  --timestamp --options runtime \
  /tmp/libosxup.dylib

lipo -archs /tmp/libosxup.dylib
codesign -dv --verbose=4 /tmp/libosxup.dylib

rm ./package/source/module/libosxup.dylib
mv /tmp/libosxup.dylib ./package/source/module/libosxup.dylib

rm -rf /tmp/build_arm64
rm -rf /tmp/build_x86_64

# build osxrdp main app
xcodebuild build -scheme "OSXRDP" -configuration Release \
  -destination "generic/platform=macOS" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  BUILD_DIR="/tmp/OSXRDP"
  
codesign --force --sign "Developer ID Application: BYEONGHO KIM (33X7M69J4B)" \
  --timestamp --options runtime --deep \
  /tmp/OSXRDP/Release/OSXRDP.app

rm -rf ./package/source/OSXRDP.app/
mv /tmp/OSXRDP/Release/OSXRDP.app ./package/source/OSXRDP.app

# build osxrdp uninstaller
xcodebuild build -scheme "OSXRDPUninstaller" -configuration Release \
  -destination "generic/platform=macOS" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  BUILD_DIR="/tmp/OSXRDPUninstaller"
  
codesign --force --sign "Developer ID Application: BYEONGHO KIM (33X7M69J4B)" \
  --timestamp --options runtime --deep \
  /tmp/OSXRDPUninstaller/Release/OSXRDPUninstaller.app

rm -rf ./package/source/OSXRDPUninstaller.app/
mv /tmp/OSXRDPUninstaller/Release/OSXRDPUninstaller.app ./package/source/OSXRDPUninstaller.app
