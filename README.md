# osxrdp - xrdp for macOS
<h6>English | <a href="README_ko.md">한국어</a></h6>

## Overview
osxrdp is an unofficial module of xrdp to support rdp server in macOS.
<img width="1282" height="832" alt="OSXRDP" src="https://github.com/user-attachments/assets/539b2870-b5c6-4d16-90b0-ad6d2799951a" />

<h6><a href="https://www.youtube.com/watch?v=ltxx2bha5-8">Video</a></h6>

## Features
|Features|Status|
|------|---|
|Smooth Remote Control (H.264)|✅|
|Virtual monitor (for dynamic resolution)|✅|
|Remote control for non logoned macOS user|✅|
|Basic Clipboard (Text)|✅|
|Advanced Clipboard (Image, Rich Text)|✅|
|Audio|❌|
|File transfer|❌|
|Multiple monitor|❌|

## Manual
<h6><a href="Manual.md">Link</a></h6>

## Limitation
* osxrdp is still in alpha version. It may contain numerous bugs and is not suitable for production use.

## Known Issuses
* Using mstsc on Windows 11, if you minimize the mstsc window and then reopen it, the image quality deteriorates slightly.\
  This issue can be resolved by disabling 'Hardware Accelerated Decoding' in mstsc. (Frame rate may drop.)
  <img width="1439" height="347" alt="image" src="https://github.com/user-attachments/assets/e6bf66cd-0caa-4259-8d5a-3410c440a2f6" />

## Supported OS
macOS 12.4 or higher version.\
Support Apple Silicon & Intel mac.

## Etc
osxrdp is compatible with original xrdp v0.10.5 version. (no modificated)

