# osxrdp - xrdp for macOS
<h6>English | <a href="README_ko.md">한국어</a></h6>

## Overview
osxrdp is an unofficial module of xrdp to support rdp server in macOS.
<img width="1282" height="832" alt="OSXRDP" src="https://github.com/user-attachments/assets/539b2870-b5c6-4d16-90b0-ad6d2799951a" />

<h6><a href="https://youtu.be/fqtFD4xAFJo">Video</a></h6>

## Features
|Features|Status|
|------|---|
|Smooth Remote Control (H.264)|✅|
|Remote control for non logoned macOS user|❌|
|Session Resizing & Virtual native resoulution|❌|
|Audio|❌|
|Clipboard|❌|
|File transfer|❌|
|Multiple monitor|❌|

## Manual
<h6><a href="Manual.md">Link</a></h6>

## Limitation
* On first boot, you must access the physical computer and unlock it directly.\
  This is a limitation of FileVault and cannot be resolved.
* osxrdp is still in alpha version. It may contain numerous bugs and is not suitable for production use.

## Known Issuses
* The host computer must have at least one physical monitor connected to it.
* Since virtual resolution is not yet supported, the image quality may be degraded if the resolution of the host computer's monitor is different.
* The mouse cursor does not change shape according to the situation.
* Using mstsc, if you minimize the mstsc window and then reopen it, the image quality deteriorates slightly. I'm not sure why this is happening.
  
## Supported OS
macOS 12.4 or higher version.\
Support Apple Silicon & Intel mac.
