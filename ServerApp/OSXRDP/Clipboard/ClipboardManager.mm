#include "ClipboardManager.h"

#import <AppKit/AppKit.h>
#import "../UI/ProgressDialog/FileCopyWindow.h"
#include "osxrdp/packet.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const int XR_CHANNEL_FLAG_FIRST = 0x00000001;
static const int XR_CHANNEL_FLAG_LAST = 0x00000002;

static const int CB_MONITOR_READY = 1;
static const int CB_FORMAT_LIST = 2;
static const int CB_FORMAT_LIST_RESPONSE = 3;
static const int CB_FORMAT_DATA_REQUEST = 4;
static const int CB_FORMAT_DATA_RESPONSE = 5;
static const int CB_CLIP_CAPS = 7;
static const int CB_FILECONTENTS_REQUEST = 8;
static const int CB_FILECONTENTS_RESPONSE = 9;
static const int CB_LOCK_CLIPDATA = 10;
static const int CB_UNLOCK_CLIPDATA = 11;

static const int CB_RESPONSE_OK = 0x0001;
static const int CB_RESPONSE_FAIL = 0x0002;
static const int CB_ASCII_NAMES = 0x0004;

static const int CF_TEXT = 1;
static const int CF_DIB = 8;
static const int CF_UNICODETEXT = 13;
static const int CF_OEMTEXT = 7;

static const int LOCAL_RTF_FORMAT_ID = 0xC001;
static const int LOCAL_FILEGROUP_FORMAT_ID = 0xC0BC;
static const int LOCAL_FILECONTENTS_FORMAT_ID = 0xC0BA;
static const int LOCAL_DROPEFFECT_FORMAT_ID = 0xC0C1;
static const char* RTF_FORMAT_NAME = "Rich Text Format";
static const char* FILEGROUP_FORMAT_NAME = "FileGroupDescriptorW";
static const char* FILECONTENTS_FORMAT_NAME = "FileContents";
static const char* DROPEFFECT_FORMAT_NAME = "DropEffect";

// 클립보드 모니터링 주기
static const useconds_t CLIPBOARD_MONITOR_INTERVAL_US = 500000;

// 한번에 전송할 클립보드 데이터의 크기 (바이트)
static const int IPC_CLIPBOARD_CHUNK_SIZE = 14 * 1024;
static const int MAX_CLIPBOARD_DATA_SIZE = 30 * 1024 * 1024; // 30MB
static const int MAX_FILECONTENTS_CHUNK_SIZE = 4 * 1024 * 1024;
static const int REMOTE_FILE_COPY_CHUNK_SIZE = 1024 * 1024;
static const int INVALID_CHANGE_COUNT = -1;

static const int FILECONTENTS_SIZE = 0x00000001;
static const int FILECONTENTS_RANGE = 0x00000002;

static const int FD_ATTRIBUTES = 0x00000004;
static const int FD_WRITESTIME = 0x00000020;
static const int FD_FILESIZE = 0x00000040;
static const int FD_SHOWPROGRESSUI = 0x00004000;

static const int FILE_ATTRIBUTE_DIRECTORY = 0x00000010;
static const int FILE_ATTRIBUTE_NORMAL = 0x00000080;
static const int CLIPRDR_FILEDESCRIPTOR_SIZE = 592;
static const int DROPEFFECT_COPY = 1;

static const int CB_CAPSTYPE_GENERAL = 1;
static const int CB_STREAM_FILECLIP_ENABLED = 0x00000004;
static const int CB_CAN_LOCK_CLIPDATA = 0x00000010;

static int ReadUInt16LE(const unsigned char* data) {
    return (int)((uint16_t)data[0] | ((uint16_t)data[1] << 8));
}

static int ReadUInt32LE(const unsigned char* data) {
    return (int)((uint32_t)data[0] |
                 ((uint32_t)data[1] << 8) |
                 ((uint32_t)data[2] << 16) |
                 ((uint32_t)data[3] << 24));
}

static bool IsKnownClipMsgType(int msgType) {
    return msgType == CB_MONITOR_READY ||
           msgType == CB_FORMAT_LIST ||
           msgType == CB_FORMAT_LIST_RESPONSE ||
           msgType == CB_FORMAT_DATA_REQUEST ||
           msgType == CB_FORMAT_DATA_RESPONSE ||
           msgType == CB_CLIP_CAPS ||
           msgType == CB_FILECONTENTS_REQUEST ||
           msgType == CB_FILECONTENTS_RESPONSE;
}

static void WriteFormatName(xstream_t* clipStream, const char* formatName) {
    if (clipStream == NULL) {
        return;
    }

    if (formatName == NULL) {
        xstream_writeInt16(clipStream, 0);
        return;
    }

    int nameLen = (int)strlen(formatName);
    int i = 0;

    for (i = 0; i < nameLen; i++) {
        xstream_writeInt16(clipStream, (unsigned char)formatName[i]);
    }

    xstream_writeInt16(clipStream, 0);
}

NSMutableArray* ClipboardManager::LocalFileItems() {
    return (__bridge NSMutableArray*)_localFileItems;
}

static NSMutableArray* RemoteFileItems(void* items) {
    return (__bridge NSMutableArray*)items;
}

static FileCopyWindow* FileCopyProgressWindow(void* window) {
    return (__bridge FileCopyWindow*)window;
}

static NSFileHandle* FileCopyCurrentHandle(void* handle) {
    return (__bridge NSFileHandle*)handle;
}

static NSString* FileCopyCurrentPath(void* path) {
    return (__bridge NSString*)path;
}

uint64_t ClipboardManager::ReadUInt64FromLowHigh(int low, int high) {
    return (((uint64_t)(uint32_t)high) << 32) | (uint32_t)low;
}

void ClipboardManager::WriteUInt64ToBuffer(unsigned char* buffer, uint64_t value) {
    for (int i = 0; i < 8; i++) {
        buffer[i] = (unsigned char)((value >> (i * 8)) & 0xFF);
    }
}

uint64_t ClipboardManager::FileTimeFromDate(NSDate* date) {
    if (date == nil) {
        return 0;
    }

    NSTimeInterval seconds = [date timeIntervalSince1970] + 11644473600.0;
    return (uint64_t)(seconds * 10000000.0);
}

void ClipboardManager::WriteFileName(xstream_t* stream, NSString* fileName) {
    unsigned char nameBuffer[520] = {0,};
    NSString* normalizedName = [[fileName precomposedStringWithCanonicalMapping] stringByReplacingOccurrencesOfString:@"/" withString:@"\\"];
    NSData* nameData = [normalizedName dataUsingEncoding:NSUTF16LittleEndianStringEncoding];

    NSUInteger copyLen = [nameData length];
    if (copyLen > sizeof(nameBuffer) - 2) {
        copyLen = sizeof(nameBuffer) - 2;
    }
    copyLen -= copyLen % 2;

    if (copyLen > 0) {
        memcpy(nameBuffer, [nameData bytes], copyLen);
    }

    xstream_writeData(stream, nameBuffer, sizeof(nameBuffer));
}

void ClipboardManager::AddLocalFileItem(NSMutableArray* items, NSURL* url, NSString* name) {
    if (items == nil || url == nil || name == nil || [name length] == 0) {
        return;
    }

    NSNumber* isDirNumber = nil;
    NSNumber* fileSizeNumber = nil;
    NSDate* modifiedDate = nil;

    [url getResourceValue:&isDirNumber forKey:NSURLIsDirectoryKey error:nil];
    [url getResourceValue:&fileSizeNumber forKey:NSURLFileSizeKey error:nil];
    [url getResourceValue:&modifiedDate forKey:NSURLContentModificationDateKey error:nil];

    BOOL isDir = [isDirNumber boolValue];
    uint64_t fileSize = isDir ? 0 : (uint64_t)[fileSizeNumber unsignedLongLongValue];
    uint64_t fileTime = FileTimeFromDate(modifiedDate);

    NSDictionary* item = [NSDictionary dictionaryWithObjectsAndKeys:
                          url, @"url",
                          name, @"name",
                          [NSNumber numberWithBool:isDir], @"isDir",
                          [NSNumber numberWithUnsignedLongLong:fileSize], @"size",
                          [NSNumber numberWithUnsignedLongLong:fileTime], @"mtime",
                          nil];
    [items addObject:item];
}

void ClipboardManager::AddLocalFileTree(NSMutableArray* items, NSURL* rootUrl) {
    if (items == nil || rootUrl == nil || [rootUrl isFileURL] == NO) {
        return;
    }

    NSString* rootName = [[rootUrl path] lastPathComponent];
    AddLocalFileItem(items, rootUrl, rootName);

    NSNumber* isDirNumber = nil;
    [rootUrl getResourceValue:&isDirNumber forKey:NSURLIsDirectoryKey error:nil];
    if ([isDirNumber boolValue] == NO) {
        return;
    }

    NSArray* keys = [NSArray arrayWithObjects:NSURLIsDirectoryKey, NSURLFileSizeKey, NSURLContentModificationDateKey, nil];
    NSDirectoryEnumerator* enumerator = [[NSFileManager defaultManager] enumeratorAtURL:rootUrl
                                                             includingPropertiesForKeys:keys
                                                                                options:0
                                                                           errorHandler:nil];
    NSString* rootPath = [rootUrl path];
    for (NSURL* childUrl in enumerator) {
        NSString* childPath = [childUrl path];
        if ([childPath length] <= [rootPath length] + 1) {
            continue;
        }

        NSString* suffix = [childPath substringFromIndex:[rootPath length] + 1];
        NSString* childName = [rootName stringByAppendingPathComponent:suffix];
        AddLocalFileItem(items, childUrl, childName);
    }
}

NSString* ClipboardManager::ReadFileDescriptorName(const unsigned char* data, int dataLen) {
    if (data == NULL || dataLen <= 0) {
        return nil;
    }

    int nameLen = 0;
    while (nameLen + 1 < dataLen) {
        if (data[nameLen] == 0 && data[nameLen + 1] == 0) {
            break;
        }
        nameLen += 2;
    }

    if (nameLen <= 0) {
        return nil;
    }

    NSData* nameData = [NSData dataWithBytes:data length:nameLen];
    NSString* name = [[NSString alloc] initWithData:nameData encoding:NSUTF16LittleEndianStringEncoding];
    return name;
}

bool ClipboardManager::IsSafeRelativeFileName(NSString* fileName) {
    if (fileName == nil || [fileName length] == 0 || [fileName isAbsolutePath] == YES) {
        return false;
    }

    NSArray* components = [fileName componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\\/"]];
    for (NSString* component in components) {
        if ([component length] == 0 || [component isEqualToString:@"."] || [component isEqualToString:@".."]) {
            return false;
        }
    }

    return true;
}

NSURL* ClipboardManager::MakeUniqueChildUrl(NSURL* folderUrl, NSString* fileName) {
    if (folderUrl == nil || fileName == nil || [fileName length] == 0) {
        return nil;
    }

    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSString* baseName = [fileName stringByDeletingPathExtension];
    NSString* pathExtension = [fileName pathExtension];
    NSURL* candidate = [folderUrl URLByAppendingPathComponent:fileName];
    int index = 2;

    while ([fileManager fileExistsAtPath:[candidate path]]) {
        NSString* nextName = nil;
        if ([pathExtension length] > 0 && [baseName length] > 0) {
            nextName = [NSString stringWithFormat:@"%@ (%d).%@", baseName, index, pathExtension];
        } else {
            nextName = [NSString stringWithFormat:@"%@ (%d)", fileName, index];
        }

        candidate = [folderUrl URLByAppendingPathComponent:nextName];
        index++;
    }

    return candidate;
}

static bool BuildDibFromImage(NSImage* image, char** outData, int* outDataLen) {
    if (image == nil || outData == NULL || outDataLen == NULL) {
        return false;
    }

    *outData = NULL;
    *outDataLen = 0;

    NSData* tiffData = [image TIFFRepresentation];
    if (tiffData == nil || [tiffData length] <= 0) {
        return false;
    }

    NSBitmapImageRep* sourceBitmapRep = [NSBitmapImageRep imageRepWithData:tiffData];
    if (sourceBitmapRep == nil) {
        return false;
    }

    int width = (int)[sourceBitmapRep pixelsWide];
    int height = (int)[sourceBitmapRep pixelsHigh];
    if (width <= 0 || height <= 0) {
        return false;
    }

    int sourceBytesPerRow = width * 4;
    NSBitmapImageRep* renderBitmapRep = [[NSBitmapImageRep alloc]
                                         initWithBitmapDataPlanes:NULL
                                         pixelsWide:width
                                         pixelsHigh:height
                                         bitsPerSample:8
                                         samplesPerPixel:4
                                         hasAlpha:YES
                                         isPlanar:NO
                                         colorSpaceName:NSCalibratedRGBColorSpace
                                         bitmapFormat:0
                                         bytesPerRow:sourceBytesPerRow
                                         bitsPerPixel:32];
    if (renderBitmapRep == nil) {
        return false;
    }

    NSGraphicsContext* graphicsContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:renderBitmapRep];
    if (graphicsContext == nil) {
        return false;
    }

    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:graphicsContext];
    [image drawInRect:NSMakeRect(0, 0, width, height)
             fromRect:NSZeroRect
            operation:NSCompositingOperationCopy
             fraction:1.0];
    [graphicsContext flushGraphics];
    [NSGraphicsContext restoreGraphicsState];

    unsigned char* bitmapData = [renderBitmapRep bitmapData];
    if (bitmapData == NULL) {
        return false;
    }

    int pixelDataLen = sourceBytesPerRow * height;
    int dibLen = 40 + pixelDataLen;
    char* pixelData = (char*)malloc(pixelDataLen);
    if (pixelData == NULL) {
        return false;
    }

    char* pixelWritePtr = pixelData;
    int row = 0;
    for (row = height - 1; row >= 0; row--) {
        unsigned char* srcRow = bitmapData + (row * sourceBytesPerRow);
        int col = 0;

        for (col = 0; col < width; col++) {
            pixelWritePtr[0] = srcRow[col * 4 + 2];
            pixelWritePtr[1] = srcRow[col * 4 + 1];
            pixelWritePtr[2] = srcRow[col * 4 + 0];
            pixelWritePtr[3] = 0;
            pixelWritePtr += 4;
        }
    }

    xstream_t* dibStream = xstream_create(dibLen);
    if (dibStream == NULL) {
        free(pixelData);
        return false;
    }

    xstream_writeInt32(dibStream, 40);
    xstream_writeInt32(dibStream, width);
    xstream_writeInt32(dibStream, height);
    xstream_writeInt16(dibStream, 1);
    xstream_writeInt16(dibStream, 32);
    xstream_writeInt32(dibStream, 0);
    xstream_writeInt32(dibStream, pixelDataLen);
    xstream_writeInt32(dibStream, 0);
    xstream_writeInt32(dibStream, 0);
    xstream_writeInt32(dibStream, 0);
    xstream_writeInt32(dibStream, 0);

    xstream_writeData(dibStream, pixelData, pixelDataLen);
    free(pixelData);

    int bufferLen = 0;
    const void* dibRawBuffer = xstream_get_raw_buffer(dibStream, &bufferLen);
    if (dibRawBuffer == NULL || bufferLen != dibLen) {
        xstream_free(dibStream);
        return false;
    }

    char* buffer = (char*)malloc(bufferLen);
    if (buffer == NULL) {
        xstream_free(dibStream);
        return false;
    }

    memcpy(buffer, dibRawBuffer, bufferLen);
    xstream_free(dibStream);

    *outData = buffer;
    *outDataLen = bufferLen;
    return true;
}

static bool BuildBmpFromDibData(const void* dibData, int dibLen, char** outData, int* outDataLen) {
    if ((dibData == NULL && dibLen > 0) || dibLen < 40 || outData == NULL || outDataLen == NULL) {
        return false;
    }

    *outData = NULL;
    *outDataLen = 0;

    xstream_t* dibStream = xstream_create_for_read((void*)dibData, dibLen);
    if (dibStream == NULL) {
        return false;
    }

    int headerSize = xstream_readInt32(dibStream);
    if (headerSize < 40 || headerSize > dibLen) {
        xstream_free(dibStream);
        return false;
    }

    if (xstream_readData(dibStream, 10) == NULL) {
        xstream_free(dibStream);
        return false;
    }

    int bitCount = xstream_readInt16(dibStream);
    int compression = xstream_readInt32(dibStream);
    if (xstream_readData(dibStream, 12) == NULL) {
        xstream_free(dibStream);
        return false;
    }

    int colorsUsed = xstream_readInt32(dibStream);
    xstream_free(dibStream);

    int paletteEntries = 0;
    int extraMaskSize = 0;

    if (colorsUsed > 0) {
        paletteEntries = colorsUsed;
    } else if (bitCount > 0 && bitCount <= 8) {
        paletteEntries = 1 << bitCount;
    }

    if (compression == 3 && headerSize == 40) {
        extraMaskSize = 12;
    } else if (compression == 6 && headerSize == 40) {
        extraMaskSize = 16;
    }

    int pixelOffset = 14 + headerSize + extraMaskSize + (paletteEntries * 4);
    int bmpLen = dibLen + 14;
    if (pixelOffset < 14 || pixelOffset > bmpLen) {
        return false;
    }

    xstream_t* bmpStream = xstream_create(bmpLen);
    if (bmpStream == NULL) {
        return false;
    }

    xstream_writeInt8(bmpStream, 'B');
    xstream_writeInt8(bmpStream, 'M');
    xstream_writeInt32(bmpStream, bmpLen);
    xstream_writeInt16(bmpStream, 0);
    xstream_writeInt16(bmpStream, 0);
    xstream_writeInt32(bmpStream, pixelOffset);
    xstream_writeData(bmpStream, (void*)dibData, dibLen);

    int bufferLen = 0;
    const void* bmpRawBuffer = xstream_get_raw_buffer(bmpStream, &bufferLen);
    if (bmpRawBuffer == NULL || bufferLen != bmpLen) {
        xstream_free(bmpStream);
        return false;
    }

    char* buffer = (char*)malloc(bufferLen);
    if (buffer == NULL) {
        xstream_free(bmpStream);
        return false;
    }

    memcpy(buffer, bmpRawBuffer, bufferLen);
    xstream_free(bmpStream);

    *outData = buffer;
    *outDataLen = bufferLen;
    return true;
}

ClipboardManager::ClipboardManager()
: _clipDataBuffer(NULL)
, _clipDataBufferSize(0)
, _clipDataBufferCurrentLen(0)
, _pendingClipType(PendingClipType_None)
, _pendingTextFormatId(0)
, _pendingTextRetryCount(0)
, _monitorThreadRunning(0)
, _monitorStopRequested(0)
, _client(NULL)
, _lastChangeCount(INVALID_CHANGE_COUNT)
, _remoteFileClipEnabled(0)
, _remoteCanLockClipData(0)
, _localFileItems(NULL)
, _remoteFileItems(NULL)
, _remoteFileGroupFormatId(0)
, _remoteFileContentsFormatId(0)
, _remoteFileClipboardReady(0)
, _fileCopyInProgress(0)
, _fileCopyChoosingFolder(0)
, _fileCopyCancelled(0)
, _fileCopyCurrentItemIndex(0)
, _fileCopyStreamId(1)
, _fileCopyClipDataId(0)
, _nextClipDataId(1)
, _fileCopyExpectedStreamId(0)
, _fileCopyCurrentLindex(0)
, _fileCopyCurrentOffset(0)
, _fileCopyTotalBytes(0)
, _fileCopyTransferredBytes(0)
, _fileCopyWindow(NULL)
, _fileCopyCurrentHandle(NULL)
, _fileCopyCurrentPath(NULL) {
    pthread_mutex_init(&_lock, NULL);
    _localFileItems = (__bridge_retained void*)[[NSMutableArray alloc] init];
    _remoteFileItems = (__bridge_retained void*)[[NSMutableArray alloc] init];

    NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
    if (pasteboard != nil) {
        _lastChangeCount = (int)[pasteboard changeCount];
    }

    // 클립보드 모니터링 스레드
    if (pthread_create(&_monitorThread, NULL, MonitorThreadEntry, this) == 0) {
        _monitorThreadRunning = 1;
    }
}

int ClipboardManager::GetRequestedFormatPriority(PendingClipType clipType, int formatId) {
    switch (clipType) {
        case PendingClipType_RichText:
            return 40;
        case PendingClipType_Image:
            return 30;
        case PendingClipType_Text:
            if (formatId == CF_UNICODETEXT) {
                return 20;
            }
            return 0;
        default:
            break;
    }

    return 0;
}

ClipboardManager::~ClipboardManager() {
    pthread_mutex_lock(&_lock);
    _monitorStopRequested = 1;
    pthread_mutex_unlock(&_lock);

    if (_monitorThreadRunning != 0) {
        pthread_join(_monitorThread, NULL);
        _monitorThreadRunning = 0;
    }

    ResetChannelBuffer();
    if (_localFileItems != NULL) {
        CFRelease(_localFileItems);
        _localFileItems = NULL;
    }
    if (_remoteFileItems != NULL) {
        CFRelease(_remoteFileItems);
        _remoteFileItems = NULL;
    }
    if (_fileCopyWindow != NULL) {
        CFRelease(_fileCopyWindow);
        _fileCopyWindow = NULL;
    }
    if (_fileCopyCurrentHandle != NULL) {
        CFRelease(_fileCopyCurrentHandle);
        _fileCopyCurrentHandle = NULL;
    }
    if (_fileCopyCurrentPath != NULL) {
        CFRelease(_fileCopyCurrentPath);
        _fileCopyCurrentPath = NULL;
    }
    pthread_mutex_destroy(&_lock);
}

bool ClipboardManager::HasRemoteFiles() {
    pthread_mutex_lock(&_lock);
    bool result = _remoteFileClipboardReady != 0 && _fileCopyInProgress == 0 && _fileCopyChoosingFolder == 0;
    pthread_mutex_unlock(&_lock);
    return result;
}

void ClipboardManager::StartRemoteFileCopy() {
    pthread_mutex_lock(&_lock);
    bool canStart = _remoteFileClipboardReady != 0 && _fileCopyInProgress == 0 && _fileCopyChoosingFolder == 0;
    xipc_t* client = _client;
    bool canLock = _remoteCanLockClipData != 0 && client != NULL;
    int clipDataId = 0;
    if (canStart) {
        _fileCopyChoosingFolder = 1;
        if (canLock) {
            clipDataId = _fileCopyClipDataId = _nextClipDataId;
            _nextClipDataId = _nextClipDataId == 0x7FFFFFFF ? 1 : _nextClipDataId + 1;
        }
    }
    bool busy = _fileCopyInProgress != 0 || _fileCopyChoosingFolder != 0;
    pthread_mutex_unlock(&_lock);

    if (canStart == false) {
        ShowFileCopyAlert(NSLocalizedString(busy ? @"filecopy.alert.in_progress" : @"filecopy.alert.no_files", nil));
        return;
    }

    if (clipDataId != 0) {
        SendClipboardDataId(client, CB_LOCK_CLIPDATA, clipDataId);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        NSOpenPanel* panel = [NSOpenPanel openPanel];
        [panel setCanChooseFiles:NO];
        [panel setCanChooseDirectories:YES];
        [panel setAllowsMultipleSelection:NO];
        [panel setCanCreateDirectories:YES];
        [panel setTitle:NSLocalizedString(@"filecopy.panel.title", nil)];
        [panel setMessage:NSLocalizedString(@"filecopy.panel.message", nil)];
        [panel setPrompt:NSLocalizedString(@"filecopy.panel.button", nil)];

        NSModalResponse response = [panel runModal];
        if (response != NSModalResponseOK || [[panel URL] isFileURL] == NO) {
            UnlockRemoteFileCopy();
            pthread_mutex_lock(&_lock);
            _fileCopyChoosingFolder = 0;
            pthread_mutex_unlock(&_lock);
            return;
        }

        BeginRemoteFileCopyToFolder([panel URL]);
    });
}

// 클라이언트에서 전달된 클립보드 이벤트
void ClipboardManager::HandleCommand(xipc_t* client, xstream_t* cmd) {
    if (client == NULL || cmd == NULL) {
        return;
    }

    int packetType = xstream_readInt32(cmd);
    // 클립보드 이벤트가 아닌 경우 drop
    if (packetType != OSXRDP_PACKETTYPE_REQ_SETCLIENTCLIP) {
        return;
    }

    if (xstream_readInt32(cmd) < 0) {
        return;
    }

    int channelFlags = xstream_readInt32(cmd);
    int totalLen = xstream_readInt32(cmd);
    int dataLen = xstream_readInt32(cmd);
    const void* data = xstream_readData(cmd, dataLen);

    if (totalLen <= 0 ||
        totalLen > MAX_CLIPBOARD_DATA_SIZE ||
        dataLen < 0 ||
        dataLen > totalLen ||
        data == NULL) {
        return;
    }

    UpdateRemoteClipboardContext(client);

    const void* completeData = NULL;
    int completeLen = 0;

    if (AssembleChannelData(channelFlags, totalLen, data, dataLen, &completeData, &completeLen) == false) {
        return;
    }

    HandleClipData(client, completeData, completeLen);

    if (completeData == _clipDataBuffer) {
        ResetChannelBuffer();
    }
}

void ClipboardManager::ResetChannelBuffer() {
    if (_clipDataBuffer != NULL) {
        free(_clipDataBuffer);
        _clipDataBuffer = NULL;
    }

    _clipDataBufferSize = 0;
    _clipDataBufferCurrentLen = 0;
}

void ClipboardManager::UpdateRemoteClipboardContext(xipc_t* client) {
    int shouldSendInitialFormatList = 0;

    pthread_mutex_lock(&_lock);
    if (client != NULL && _client != client) {
        shouldSendInitialFormatList = 1;
        _remoteCanLockClipData = 0;
    }

    _client = client;
    pthread_mutex_unlock(&_lock);

    if (shouldSendInitialFormatList != 0) {
        ProcessLocalClipboardChange(1);
    }
}

bool ClipboardManager::AssembleChannelData(int channelFlags, int totalLen, const void* data, int dataLen, const void** completeData, int* completeLen) {
    if (completeData == NULL || completeLen == NULL) {
        return false;
    }

    *completeData = NULL;
    *completeLen = 0;

    if (totalLen <= 0 || totalLen > MAX_CLIPBOARD_DATA_SIZE || dataLen < 0 || dataLen > totalLen) {
        ResetChannelBuffer();
        return false;
    }

    if ((channelFlags & XR_CHANNEL_FLAG_FIRST) != 0 &&
        (channelFlags & XR_CHANNEL_FLAG_LAST) != 0) {
        *completeData = data;
        *completeLen = dataLen;
        return true;
    }

    if ((channelFlags & XR_CHANNEL_FLAG_FIRST) != 0) {
        ResetChannelBuffer();

        _clipDataBuffer = (char*)malloc(totalLen);
        if (_clipDataBuffer == NULL) {
            return false;
        }

        _clipDataBufferSize = totalLen;
        _clipDataBufferCurrentLen = 0;
    }

    if (_clipDataBuffer == NULL || _clipDataBufferCurrentLen + dataLen > _clipDataBufferSize) {
        ResetChannelBuffer();
        return false;
    }

    memcpy(_clipDataBuffer + _clipDataBufferCurrentLen, data, dataLen);
    _clipDataBufferCurrentLen += dataLen;

    if ((channelFlags & XR_CHANNEL_FLAG_LAST) == 0) {
        return false;
    }

    *completeData = _clipDataBuffer;
    *completeLen = _clipDataBufferCurrentLen;
    return true;
}

void ClipboardManager::HandleClipData(xipc_t* client, const void* data, int dataLen) {
    if (data == NULL || dataLen < 8) {
        return;
    }

    const unsigned char* bytes = (const unsigned char*)data;
    int offset = 0;
    while (offset + 8 <= dataLen) {
        int msgType = ReadUInt16LE(bytes + offset);

        if (IsKnownClipMsgType(msgType) == false) {
            if (offset + 4 <= dataLen && ReadUInt32LE(bytes + offset) == 0) {
                offset += 4;
                continue;
            }
            break;
        }

        int msgLen = ReadUInt32LE(bytes + offset + 4);
        int packetLen = 8 + msgLen;
        if (msgLen < 0 || packetLen < 8 || packetLen > dataLen - offset) {
            break;
        }

        xstream_t* clipStream = xstream_create_for_read((void*)(bytes + offset), packetLen);
        if (clipStream == NULL) {
            return;
        }

        msgType = xstream_readInt16(clipStream);
        int msgFlags = xstream_readInt16(clipStream);
        msgLen = xstream_readInt32(clipStream);

        switch (msgType) {
            case CB_MONITOR_READY:
                UpdateRemoteClipboardContext(client);
                break;
            case CB_CLIP_CAPS:
                HandleCaps(clipStream, msgLen);
                break;
            case CB_FORMAT_LIST:
                HandleFormatList(client, clipStream, msgFlags, msgLen);
                break;
            case CB_FORMAT_DATA_REQUEST:
                HandleDataRequest(client, clipStream, msgFlags, msgLen);
                break;
            case CB_FORMAT_DATA_RESPONSE:
                HandleDataResponse(clipStream, msgFlags, msgLen);
                break;
            case CB_FILECONTENTS_REQUEST:
                HandleFileContentsRequest(client, clipStream, msgFlags, msgLen);
                break;
            case CB_FILECONTENTS_RESPONSE:
                HandleFileContentsResponse(clipStream, msgFlags, msgLen);
                break;
            default:
                break;
        }

        xstream_free(clipStream);
        offset += packetLen;
    }
}

void ClipboardManager::HandleCaps(xstream_t* clipStream, int msgLen) {
    if (msgLen < 4) {
        return;
    }

    int capCount = xstream_readInt16(clipStream);
    xstream_readInt16(clipStream);

    for (int i = 0; i < capCount && xstream_getRemaining(clipStream) >= 4; i++) {
        int type = xstream_readInt16(clipStream);
        int len = xstream_readInt16(clipStream);
        if (len < 4 || xstream_getRemaining(clipStream) < len - 4) {
            return;
        }

        if (type == CB_CAPSTYPE_GENERAL && len >= 12) {
            xstream_readInt32(clipStream);
            int flags = xstream_readInt32(clipStream);
            pthread_mutex_lock(&_lock);
            _remoteFileClipEnabled = ((flags & CB_STREAM_FILECLIP_ENABLED) != 0) ? 1 : 0;
            _remoteCanLockClipData = ((flags & CB_CAN_LOCK_CLIPDATA) != 0) ? 1 : 0;
            pthread_mutex_unlock(&_lock);
            if (len > 12) {
                xstream_readData(clipStream, len - 12);
            }
            continue;
        }

        xstream_readData(clipStream, len - 4);
    }
}

void ClipboardManager::HandleFormatList(xipc_t* client, xstream_t* clipStream, int msgFlags, int msgLen) {
    int fileGroupFormatId = 0;
    int fileContentsFormatId = 0;
    bool hasRemoteFiles = FindRemoteFileFormats(msgFlags, msgLen, clipStream, &fileGroupFormatId, &fileContentsFormatId);

    int formatId = 0;
    PendingClipType clipType = PendingClipType_None;

    FindRequestedFormat(msgFlags, msgLen, clipStream, &formatId, &clipType);

    SendFormatAck(client, true);

    if (hasRemoteFiles) {
        pthread_mutex_lock(&_lock);
        bool busy = _fileCopyInProgress != 0 || _fileCopyChoosingFolder != 0;
        pthread_mutex_unlock(&_lock);
        if (busy) {
            return;
        }

        pthread_mutex_lock(&_lock);
        _remoteFileClipboardReady = 0;
        _remoteFileGroupFormatId = fileGroupFormatId;
        _remoteFileContentsFormatId = fileContentsFormatId;
        [RemoteFileItems(_remoteFileItems) removeAllObjects];
        pthread_mutex_unlock(&_lock);

        _pendingClipType = PendingClipType_FileList;
        _pendingTextFormatId = 0;
        _pendingTextRetryCount = 0;
        SendDataRequest(client, fileGroupFormatId);
        return;
    }

    pthread_mutex_lock(&_lock);
    if (_fileCopyInProgress == 0 && _fileCopyChoosingFolder == 0) {
        _remoteFileClipboardReady = 0;
        _remoteFileGroupFormatId = 0;
        _remoteFileContentsFormatId = 0;
        [RemoteFileItems(_remoteFileItems) removeAllObjects];
    }
    pthread_mutex_unlock(&_lock);

    _pendingClipType = clipType;
    _pendingTextFormatId = (clipType == PendingClipType_Text) ? formatId : 0;
    _pendingTextRetryCount = 0;

    if (formatId == 0 || clipType == PendingClipType_None) {
        _pendingClipType = PendingClipType_None;
        _pendingTextFormatId = 0;
        _pendingTextRetryCount = 0;
        return;
    }

    SendDataRequest(client, formatId);
}

void ClipboardManager::HandleDataRequest(xipc_t* client, xstream_t* clipStream, int msgFlags, int msgLen) {
    (void)msgFlags;

    if (msgLen < 4) {
        SendDataResponseFailed(client);
        return;
    }

    int requestedFormatId = xstream_readInt32(clipStream);
    if (requestedFormatId == LOCAL_FILEGROUP_FORMAT_ID) {
        char* fileListData = NULL;
        int fileListLen = 0;

        if (BuildFileList(&fileListData, &fileListLen) == false || fileListData == NULL || fileListLen <= 0) {
            SendDataResponseFailed(client);
            return;
        }

        SendDataResponse(client, fileListData, fileListLen);
        free(fileListData);
        return;
    }
    if (requestedFormatId == LOCAL_DROPEFFECT_FORMAT_ID) {
        int dropEffect = DROPEFFECT_COPY;
        SendDataResponse(client, &dropEffect, sizeof(dropEffect));
        return;
    }

    if (requestedFormatId == LOCAL_RTF_FORMAT_ID) {
        char* rtfData = NULL;
        int rtfLen = 0;

        if (GetPasteboardRtf(&rtfData, &rtfLen) == false || rtfData == NULL || rtfLen <= 0) {
            SendDataResponseFailed(client);
            return;
        }

        SendDataResponse(client, rtfData, rtfLen);
        free(rtfData);
        return;
    }

    if (requestedFormatId == CF_DIB) {
        char* dibData = NULL;
        int dibLen = 0;

        if (GetPasteboardImage(&dibData, &dibLen) == false || dibData == NULL || dibLen <= 0) {
            SendDataResponseFailed(client);
            return;
        }

        SendDataResponse(client, dibData, dibLen);
        free(dibData);
        return;
    }

    if (requestedFormatId == CF_UNICODETEXT) {
        char* utf8Text = NULL;
        int utf8Len = 0;
        int changeCount = 0;

        if (GetPasteboardText(&utf8Text, &utf8Len, &changeCount) == false || utf8Text == NULL) {
            SendDataResponseFailed(client);
            return;
        }

        SendDataResponseText(client, utf8Text, utf8Len, requestedFormatId);
        free(utf8Text);
        return;
    }

    if (requestedFormatId == CF_TEXT || requestedFormatId == CF_OEMTEXT) {
        SendDataResponseFailed(client);
        return;
    }

    SendDataResponseFailed(client);
}

void ClipboardManager::HandleDataResponse(xstream_t* clipStream, int msgFlags, int msgLen) {
    if (_pendingClipType == PendingClipType_None) {
        return;
    }

    if ((msgFlags & CB_RESPONSE_FAIL) != 0 || (msgFlags & CB_RESPONSE_OK) == 0) {
        if (_pendingClipType == PendingClipType_Text &&
            _pendingTextFormatId == CF_UNICODETEXT &&
            _pendingTextRetryCount == 0 &&
            _client != NULL) {
            _pendingTextRetryCount = 1;
            SendDataRequest(_client, CF_UNICODETEXT);
            return;
        }
        _pendingClipType = PendingClipType_None;
        _pendingTextFormatId = 0;
        _pendingTextRetryCount = 0;
        return;
    }

    const void* data = xstream_readData(clipStream, msgLen);
    if (data == NULL && msgLen > 0) {
        _pendingClipType = PendingClipType_None;
        _pendingTextFormatId = 0;
        _pendingTextRetryCount = 0;
        return;
    }

    if (_pendingClipType == PendingClipType_FileList) {
        ParseRemoteFileList(data, msgLen);
    } else if (_pendingClipType == PendingClipType_Text) {
        SetTextToPasteboard(data, msgLen, _pendingTextFormatId);
    } else if (_pendingClipType == PendingClipType_RichText) {
        SetRtfToPasteboard(data, msgLen);
    } else if (_pendingClipType == PendingClipType_Image) {
        SetImageToPasteboard(data, msgLen);
    }

    _pendingClipType = PendingClipType_None;
    _pendingTextFormatId = 0;
    _pendingTextRetryCount = 0;
}

void ClipboardManager::HandleFileContentsRequest(xipc_t* client, xstream_t* clipStream, int msgFlags, int msgLen) {
    (void)msgFlags;

    if (msgLen < 24) {
        return;
    }

    int streamId = xstream_readInt32(clipStream);
    int lindex = xstream_readInt32(clipStream);
    int flags = xstream_readInt32(clipStream);
    uint64_t offset = ReadUInt64FromLowHigh(xstream_readInt32(clipStream), xstream_readInt32(clipStream));
    int requested = xstream_readInt32(clipStream);

    NSDictionary* item = nil;
    pthread_mutex_lock(&_lock);
    NSMutableArray* items = LocalFileItems();
    if (lindex >= 0 && lindex < (int)[items count]) {
        item = [items objectAtIndex:lindex];
    }
    pthread_mutex_unlock(&_lock);

    if (item == nil || requested < 0) {
        SendFileContentsResponseFailed(client, streamId);
        return;
    }
    if (requested > MAX_FILECONTENTS_CHUNK_SIZE) {
        requested = MAX_FILECONTENTS_CHUNK_SIZE;
    }

    BOOL isDir = [[item objectForKey:@"isDir"] boolValue];
    uint64_t fileSize = [[item objectForKey:@"size"] unsignedLongLongValue];

    if ((flags & FILECONTENTS_SIZE) != 0) {
        unsigned char sizeBuffer[8] = {0,};
        WriteUInt64ToBuffer(sizeBuffer, fileSize);
        SendFileContentsResponse(client, streamId, sizeBuffer, sizeof(sizeBuffer));
        return;
    }

    if ((flags & FILECONTENTS_RANGE) == 0 || isDir == YES || offset > fileSize) {
        SendFileContentsResponseFailed(client, streamId);
        return;
    }

    uint64_t readable = fileSize - offset;
    if ((uint64_t)requested > readable) {
        requested = (int)readable;
    }

    NSURL* url = [item objectForKey:@"url"];
    NSError* error = nil;
    NSFileHandle* fileHandle = [NSFileHandle fileHandleForReadingFromURL:url error:&error];
    if (fileHandle == nil) {
        SendFileContentsResponseFailed(client, streamId);
        return;
    }

    NSData* data = nil;
    @try {
        [fileHandle seekToFileOffset:offset];
        data = [fileHandle readDataOfLength:(NSUInteger)requested];
        [fileHandle closeFile];
    } @catch (NSException* exception) {
        SendFileContentsResponseFailed(client, streamId);
        return;
    }

    SendFileContentsResponse(client, streamId, [data bytes], (int)[data length]);
}

void ClipboardManager::FindRequestedFormat(int msgFlags, int msgLen, xstream_t* clipStream, int* formatId, PendingClipType* clipType) {
    if (clipStream == NULL || formatId == NULL || clipType == NULL) {
        return;
    }

    *formatId = 0;
    *clipType = PendingClipType_None;

    if ((msgFlags & CB_ASCII_NAMES) != 0) {
        FindRequestedFormatShortName(clipStream, msgLen, formatId, clipType);
        return;
    }

    if (msgLen > 0 && msgLen % 36 == 0) {
        FindRequestedFormatShortName(clipStream, msgLen, formatId, clipType);
        if (*formatId != 0 && *clipType != PendingClipType_None) {
            return;
        }

        xstream_resetPos(clipStream);
        xstream_readInt16(clipStream);
        xstream_readInt16(clipStream);
        xstream_readInt32(clipStream);
    }

    FindRequestedFormatLongName(clipStream, msgLen, formatId, clipType);
}

void ClipboardManager::FindRequestedFormatLongName(xstream_t* clipStream, int msgLen, int* formatId, PendingClipType* clipType) {
    if (clipStream == NULL || formatId == NULL || clipType == NULL) {
        return;
    }

    int readLen = 0;
    int bestPriority = 0;

    while (readLen + 4 <= msgLen) {
        int currentFormatId = xstream_readInt32(clipStream);
        int currentClipType = PendingClipType_None;
        char formatName[64];
        int namePos = 0;
        bool foundTerminator = false;

        readLen += 4;

        if (currentFormatId == CF_UNICODETEXT ||
            currentFormatId == CF_TEXT ||
            currentFormatId == CF_OEMTEXT) {
            currentClipType = PendingClipType_Text;
        } else if (currentFormatId == CF_DIB) {
            currentClipType = PendingClipType_Image;
        }

        while (readLen + 2 <= msgLen) {
            int ch = xstream_readInt16(clipStream);
            readLen += 2;

            if (ch == 0) {
                foundTerminator = true;
                break;
            }

            if (namePos + 1 < (int)sizeof(formatName) && ch >= 0 && ch <= 0x7F) {
                formatName[namePos++] = (char)ch;
            }
        }

        if (foundTerminator == false) {
            return;
        }

        formatName[namePos] = 0;

        if (strcmp(formatName, RTF_FORMAT_NAME) == 0) {
            currentClipType = PendingClipType_RichText;
        }

        int priority = GetRequestedFormatPriority((PendingClipType)currentClipType, currentFormatId);
        if (priority > bestPriority) {
            bestPriority = priority;
            *formatId = currentFormatId;
            *clipType = (PendingClipType)currentClipType;
        }
    }
}

void ClipboardManager::FindRequestedFormatShortName(xstream_t* clipStream, int msgLen, int* formatId, PendingClipType* clipType) {
    if (clipStream == NULL || formatId == NULL || clipType == NULL) {
        return;
    }

    int readLen = 0;
    int bestPriority = 0;

    while (readLen + 36 <= msgLen) {
        int currentFormatId = xstream_readInt32(clipStream);
        const char* formatName = (const char*)xstream_readData(clipStream, 32);
        int currentClipType = PendingClipType_None;

        if (formatName == NULL) {
            return;
        }

        readLen += 36;

        if (currentFormatId == CF_UNICODETEXT ||
            currentFormatId == CF_TEXT ||
            currentFormatId == CF_OEMTEXT) {
            currentClipType = PendingClipType_Text;
        } else if (currentFormatId == CF_DIB) {
            currentClipType = PendingClipType_Image;
        }

        if (strncmp(formatName, RTF_FORMAT_NAME, 32) == 0) {
            currentClipType = PendingClipType_RichText;
        }

        int priority = GetRequestedFormatPriority((PendingClipType)currentClipType, currentFormatId);
        if (priority > bestPriority) {
            bestPriority = priority;
            *formatId = currentFormatId;
            *clipType = (PendingClipType)currentClipType;
        }
    }

    if (readLen != msgLen) {
        *formatId = 0;
        *clipType = PendingClipType_None;
    }
}

bool ClipboardManager::FindRemoteFileFormats(int msgFlags, int msgLen, xstream_t* clipStream, int* fileGroupFormatId, int* fileContentsFormatId) {
    if (clipStream == NULL || fileGroupFormatId == NULL || fileContentsFormatId == NULL) {
        return false;
    }

    *fileGroupFormatId = 0;
    *fileContentsFormatId = 0;

    xstream_resetPos(clipStream);
    xstream_readInt16(clipStream);
    xstream_readInt16(clipStream);
    xstream_readInt32(clipStream);

    int readLen = 0;
    if ((msgFlags & CB_ASCII_NAMES) != 0 || (msgLen > 0 && msgLen % 36 == 0)) {
        while (readLen + 36 <= msgLen) {
            int formatId = xstream_readInt32(clipStream);
            const char* formatName = (const char*)xstream_readData(clipStream, 32);
            if (formatName == NULL) {
                break;
            }

            if (strncmp(formatName, FILEGROUP_FORMAT_NAME, 32) == 0) {
                *fileGroupFormatId = formatId;
            } else if (strncmp(formatName, FILECONTENTS_FORMAT_NAME, 32) == 0) {
                *fileContentsFormatId = formatId;
            }
            readLen += 36;
        }
    } else {
        while (readLen + 4 <= msgLen) {
            int formatId = xstream_readInt32(clipStream);
            char formatName[64];
            int namePos = 0;
            bool foundTerminator = false;

            readLen += 4;
            while (readLen + 2 <= msgLen) {
                int ch = xstream_readInt16(clipStream);
                readLen += 2;

                if (ch == 0) {
                    foundTerminator = true;
                    break;
                }

                if (namePos + 1 < (int)sizeof(formatName) && ch >= 0 && ch <= 0x7F) {
                    formatName[namePos++] = (char)ch;
                }
            }

            if (foundTerminator == false) {
                break;
            }

            formatName[namePos] = 0;
            if (strcmp(formatName, FILEGROUP_FORMAT_NAME) == 0) {
                *fileGroupFormatId = formatId;
            } else if (strcmp(formatName, FILECONTENTS_FORMAT_NAME) == 0) {
                *fileContentsFormatId = formatId;
            }
        }
    }

    xstream_resetPos(clipStream);
    xstream_readInt16(clipStream);
    xstream_readInt16(clipStream);
    xstream_readInt32(clipStream);

    return *fileGroupFormatId != 0 && *fileContentsFormatId != 0;
}

void* ClipboardManager::MonitorThreadEntry(void* arg) {
    ClipboardManager* _this = (ClipboardManager*)arg;
    if (_this == NULL) {
        return NULL;
    }

    @autoreleasepool {
        _this->MonitorClipboardLoop();
    }

    return NULL;
}

void ClipboardManager::MonitorClipboardLoop() {
    while (1) {
        pthread_mutex_lock(&_lock);
        int shouldStop = _monitorStopRequested;
        pthread_mutex_unlock(&_lock);

        if (shouldStop != 0) {
            break;
        }

        @autoreleasepool {
            ProcessLocalClipboardChange(0);
        }

        usleep(CLIPBOARD_MONITOR_INTERVAL_US);
    }
}

void ClipboardManager::ProcessLocalClipboardChange(int forceSend) {
    xipc_t* client = NULL;
    int lastChangeCount = 0;

    pthread_mutex_lock(&_lock);
    client = _client;
    lastChangeCount = _lastChangeCount;
    pthread_mutex_unlock(&_lock);

    if (client == NULL) {
        return;
    }

    int changeCount = 0;
    if (GetPasteboardText(NULL, NULL, &changeCount) == false) {
        return;
    }

    if (forceSend == 0 && lastChangeCount != INVALID_CHANGE_COUNT && changeCount == lastChangeCount) {
        return;
    }

    pthread_mutex_lock(&_lock);
    _lastChangeCount = changeCount;
    pthread_mutex_unlock(&_lock);

    SendFormatList(client);
}

void ClipboardManager::SendFormatAck(xipc_t* client, bool success) {
    xstream_t* clipStream = xstream_create(12);
    if (clipStream == NULL) {
        return;
    }

    xstream_writeInt16(clipStream, CB_FORMAT_LIST_RESPONSE);
    xstream_writeInt16(clipStream, success ? CB_RESPONSE_OK : CB_RESPONSE_FAIL);
    xstream_writeInt32(clipStream, 0);
    xstream_writeInt32(clipStream, 0);

    int bufferLen = 0;
    const void* buffer = xstream_get_raw_buffer(clipStream, &bufferLen);
    SendChannelData(client, buffer, bufferLen);

    xstream_free(clipStream);
}

void ClipboardManager::SendFormatList(xipc_t* client) {
    NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
    if (pasteboard == nil) {
        return;
    }

    NSString* text = [pasteboard stringForType:NSPasteboardTypeString];
    NSData* rtfData = [pasteboard dataForType:NSPasteboardTypeRTF];
    NSImage* image = [[NSImage alloc] initWithPasteboard:pasteboard];
    bool hasFile = UpdatePasteboardFileItems(NULL);
    if (hasFile && _remoteFileClipEnabled == 0) {
        hasFile = false;
    }

    bool hasText = (text != nil && [text length] > 0);
    bool hasRtf = (rtfData != nil && [rtfData length] > 0);
    bool hasImage = (image != nil);
    if (hasFile) {
        hasText = false;
        hasRtf = false;
        hasImage = false;
    }

    if (hasText == false && hasRtf == false && hasImage == false && hasFile == false) {
        return;
    }

    int dataLen = 0;
    if (hasFile) {
        dataLen += 4 + (((int)strlen(FILEGROUP_FORMAT_NAME) + 1) * 2);
        dataLen += 4 + (((int)strlen(FILECONTENTS_FORMAT_NAME) + 1) * 2);
        dataLen += 4 + (((int)strlen(DROPEFFECT_FORMAT_NAME) + 1) * 2);
    }
    if (hasRtf) {
        dataLen += 4 + (((int)strlen(RTF_FORMAT_NAME) + 1) * 2);
    }
    if (hasText) {
        dataLen += 6;
    }
    if (hasImage) {
        dataLen += 6;
    }

    xstream_t* clipStream = xstream_create(dataLen + 12);
    if (clipStream == NULL) {
        return;
    }

    xstream_writeInt16(clipStream, CB_FORMAT_LIST);
    xstream_writeInt16(clipStream, 0);
    xstream_writeInt32(clipStream, dataLen);

    if (hasFile) {
        xstream_writeInt32(clipStream, LOCAL_FILEGROUP_FORMAT_ID);
        WriteFormatName(clipStream, FILEGROUP_FORMAT_NAME);
        xstream_writeInt32(clipStream, LOCAL_FILECONTENTS_FORMAT_ID);
        WriteFormatName(clipStream, FILECONTENTS_FORMAT_NAME);
        xstream_writeInt32(clipStream, LOCAL_DROPEFFECT_FORMAT_ID);
        WriteFormatName(clipStream, DROPEFFECT_FORMAT_NAME);
    }

    if (hasRtf) {
        xstream_writeInt32(clipStream, LOCAL_RTF_FORMAT_ID);
        WriteFormatName(clipStream, RTF_FORMAT_NAME);
    }

    if (hasText) {
        xstream_writeInt32(clipStream, CF_UNICODETEXT);
        WriteFormatName(clipStream, NULL);
    }

    if (hasImage) {
        xstream_writeInt32(clipStream, CF_DIB);
        WriteFormatName(clipStream, NULL);
    }
    xstream_writeInt32(clipStream, 0);

    int bufferLen = 0;
    const void* buffer = xstream_get_raw_buffer(clipStream, &bufferLen);
    SendChannelData(client, buffer, bufferLen);

    xstream_free(clipStream);
}

void ClipboardManager::SendDataRequest(xipc_t* client, int formatId) {
    xstream_t* clipStream = xstream_create(16);
    if (clipStream == NULL) {
        return;
    }

    xstream_writeInt16(clipStream, CB_FORMAT_DATA_REQUEST);
    xstream_writeInt16(clipStream, 0);
    xstream_writeInt32(clipStream, 4);
    xstream_writeInt32(clipStream, formatId);
    xstream_writeInt32(clipStream, 0);

    int bufferLen = 0;
    const void* buffer = xstream_get_raw_buffer(clipStream, &bufferLen);
    SendChannelData(client, buffer, bufferLen);

    xstream_free(clipStream);
}

void ClipboardManager::SendDataResponse(xipc_t* client, const void* data, int dataLen) {
    if ((data == NULL && dataLen > 0) || dataLen < 0) {
        SendDataResponseFailed(client);
        return;
    }

    if (dataLen > MAX_CLIPBOARD_DATA_SIZE) {
        SendDataResponseFailed(client);
        return;
    }

    xstream_t* headerStream = xstream_create(8);
    if (headerStream == NULL) {
        SendDataResponseFailed(client);
        return;
    }

    xstream_writeInt16(headerStream, CB_FORMAT_DATA_RESPONSE);
    xstream_writeInt16(headerStream, CB_RESPONSE_OK);
    xstream_writeInt32(headerStream, dataLen);

    int headerLen = 0;
    const char* header = (const char*)xstream_get_raw_buffer(headerStream, &headerLen);
    if (header == NULL || headerLen != 8) {
        xstream_free(headerStream);
        SendDataResponseFailed(client);
        return;
    }

    static const char footer[4] = {0, 0, 0, 0};
    SendChannelDataParts(client, header, headerLen, data, dataLen, footer, sizeof(footer));
    xstream_free(headerStream);
}

void ClipboardManager::SendDataResponseText(xipc_t* client, const char* utf8Text, int utf8Len, int formatId) {
    if (utf8Text == NULL || utf8Len < 0) {
        SendDataResponseFailed(client);
        return;
    }

    char* textData = NULL;
    int textDataLen = 0;
    if (BuildWindowsText(utf8Text, utf8Len, formatId, &textData, &textDataLen) == false || textData == NULL) {
        SendDataResponseFailed(client);
        return;
    }

    SendDataResponse(client, textData, textDataLen);
    free(textData);
}

void ClipboardManager::SendDataResponseFailed(xipc_t* client) {
    xstream_t* clipStream = xstream_create(8);
    if (clipStream == NULL) {
        return;
    }

    xstream_writeInt16(clipStream, CB_FORMAT_DATA_RESPONSE);
    xstream_writeInt16(clipStream, CB_RESPONSE_FAIL);
    xstream_writeInt32(clipStream, 0);

    int bufferLen = 0;
    const void* buffer = xstream_get_raw_buffer(clipStream, &bufferLen);
    SendChannelData(client, buffer, bufferLen);

    xstream_free(clipStream);
}

void ClipboardManager::SendClipboardDataId(xipc_t* client, int msgType, int clipDataId) {
    xstream_t* clipStream = xstream_create(16);
    if (clipStream == NULL) {
        return;
    }

    xstream_writeInt16(clipStream, msgType);
    xstream_writeInt16(clipStream, 0);
    xstream_writeInt32(clipStream, 4);
    xstream_writeInt32(clipStream, clipDataId);
    xstream_writeInt32(clipStream, 0);

    int bufferLen = 0;
    SendChannelData(client, xstream_get_raw_buffer(clipStream, &bufferLen), bufferLen);
    xstream_free(clipStream);
}

void ClipboardManager::SendFileContentsRequest(xipc_t* client, int streamId, int lindex, int flags, uint64_t offset, int requested, int clipDataId) {
    int dataLen = clipDataId != 0 ? 28 : 24;
    xstream_t* clipStream = xstream_create(dataLen + 12);
    if (clipStream == NULL) {
        return;
    }

    xstream_writeInt16(clipStream, CB_FILECONTENTS_REQUEST);
    xstream_writeInt16(clipStream, 0);
    xstream_writeInt32(clipStream, dataLen);
    xstream_writeInt32(clipStream, streamId);
    xstream_writeInt32(clipStream, lindex);
    xstream_writeInt32(clipStream, flags);
    xstream_writeInt32(clipStream, (int)(offset & 0xFFFFFFFF));
    xstream_writeInt32(clipStream, (int)((offset >> 32) & 0xFFFFFFFF));
    xstream_writeInt32(clipStream, requested);
    if (clipDataId != 0) {
        xstream_writeInt32(clipStream, clipDataId);
    }
    xstream_writeInt32(clipStream, 0);

    int bufferLen = 0;
    const void* buffer = xstream_get_raw_buffer(clipStream, &bufferLen);
    SendChannelData(client, buffer, bufferLen);

    xstream_free(clipStream);
}

void ClipboardManager::SendFileContentsResponse(xipc_t* client, int streamId, const void* data, int dataLen) {
    if ((data == NULL && dataLen > 0) || dataLen < 0 || dataLen > MAX_FILECONTENTS_CHUNK_SIZE) {
        SendFileContentsResponseFailed(client, streamId);
        return;
    }

    xstream_t* headerStream = xstream_create(12);
    if (headerStream == NULL) {
        SendFileContentsResponseFailed(client, streamId);
        return;
    }

    xstream_writeInt16(headerStream, CB_FILECONTENTS_RESPONSE);
    xstream_writeInt16(headerStream, CB_RESPONSE_OK);
    xstream_writeInt32(headerStream, dataLen + 4);
    xstream_writeInt32(headerStream, streamId);

    int headerLen = 0;
    const void* header = xstream_get_raw_buffer(headerStream, &headerLen);
    SendChannelDataParts(client, header, headerLen, data, dataLen, NULL, 0);
    xstream_free(headerStream);
}

void ClipboardManager::SendFileContentsResponseFailed(xipc_t* client, int streamId) {
    xstream_t* clipStream = xstream_create(12);
    if (clipStream == NULL) {
        return;
    }

    xstream_writeInt16(clipStream, CB_FILECONTENTS_RESPONSE);
    xstream_writeInt16(clipStream, CB_RESPONSE_FAIL);
    xstream_writeInt32(clipStream, 4);
    xstream_writeInt32(clipStream, streamId);

    int bufferLen = 0;
    const void* buffer = xstream_get_raw_buffer(clipStream, &bufferLen);
    SendChannelData(client, buffer, bufferLen);

    xstream_free(clipStream);
}

void ClipboardManager::SendChannelData(xipc_t* client, const void* data, int dataLen) {
    SendChannelDataParts(client, NULL, 0, data, dataLen, NULL, 0);
}

void ClipboardManager::SendChannelDataParts(xipc_t* client, const void* header, int headerLen, const void* data, int dataLen, const void* footer, int footerLen) {
    if (client == NULL) {
        return;
    }

    if ((header == NULL && headerLen > 0) ||
        (data == NULL && dataLen > 0) ||
        (footer == NULL && footerLen > 0)) {
        return;
    }

    const int totalLen = headerLen + dataLen + footerLen;
    if (totalLen <= 0 || totalLen > MAX_CLIPBOARD_DATA_SIZE) {
        return;
    }

    const char* rawHeader = (const char*)header;
    const char* rawData = (const char*)data;
    const char* rawFooter = (const char*)footer;
    int offset = 0;

    while (offset < totalLen) {
        int chunkLen = totalLen - offset;
        if (chunkLen > IPC_CLIPBOARD_CHUNK_SIZE) {
            chunkLen = IPC_CLIPBOARD_CHUNK_SIZE;
        }

        char* chunkBuffer = (char*)malloc(chunkLen);
        if (chunkBuffer == NULL) {
            return;
        }

        int chunkOffset = 0;
        int currentOffset = offset;

        if (currentOffset < headerLen) {
            int copyLen = headerLen - currentOffset;
            if (copyLen > chunkLen - chunkOffset) {
                copyLen = chunkLen - chunkOffset;
            }

            memcpy(chunkBuffer + chunkOffset, rawHeader + currentOffset, copyLen);
            chunkOffset += copyLen;
            currentOffset += copyLen;
        }

        if (chunkOffset < chunkLen && currentOffset < headerLen + dataLen) {
            int dataOffset = currentOffset - headerLen;
            int copyLen = dataLen - dataOffset;
            if (copyLen > chunkLen - chunkOffset) {
                copyLen = chunkLen - chunkOffset;
            }

            memcpy(chunkBuffer + chunkOffset, rawData + dataOffset, copyLen);
            chunkOffset += copyLen;
            currentOffset += copyLen;
        }

        if (chunkOffset < chunkLen && currentOffset < totalLen) {
            int footerOffset = currentOffset - (headerLen + dataLen);
            int copyLen = footerLen - footerOffset;
            if (copyLen > chunkLen - chunkOffset) {
                copyLen = chunkLen - chunkOffset;
            }

            memcpy(chunkBuffer + chunkOffset, rawFooter + footerOffset, copyLen);
            chunkOffset += copyLen;
        }

        int channelFlags = 0;
        if (offset == 0) {
            channelFlags |= XR_CHANNEL_FLAG_FIRST;
        }
        if (offset + chunkLen >= totalLen) {
            channelFlags |= XR_CHANNEL_FLAG_LAST;
        }

        xstream_t* stream = xstream_create(chunkLen + sizeof(int) * 5);
        if (stream == NULL) {
            return;
        }

        xstream_writeInt32(stream, OSXRDP_CMDTYPE_CLIPBOARD);
        xstream_writeInt32(stream, OSXRDP_PACKETTYPE_REP_SETCLIENTCLIP);
        xstream_writeInt32(stream, channelFlags);
        xstream_writeInt32(stream, totalLen);
        xstream_writeInt32(stream, chunkLen);
        xstream_writeData(stream, chunkBuffer, chunkLen);

        int bufferLen = 0;
        const void* buffer = xstream_get_raw_buffer(stream, &bufferLen);
        xipc_send_data(client, buffer, bufferLen);

        xstream_free(stream);
        free(chunkBuffer);
        offset += chunkLen;
    }
}

bool ClipboardManager::UpdatePasteboardFileItems(int* itemCount) {
    if (itemCount != NULL) {
        *itemCount = 0;
    }

    NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
    if (pasteboard == nil) {
        return false;
    }

    NSArray* classes = [NSArray arrayWithObject:[NSURL class]];
    NSDictionary* options = [NSDictionary dictionaryWithObject:[NSNumber numberWithBool:YES]
                                                        forKey:NSPasteboardURLReadingFileURLsOnlyKey];
    NSArray* urls = [pasteboard readObjectsForClasses:classes options:options];
    NSMutableArray* newItems = [NSMutableArray array];

    for (NSURL* url in urls) {
        if ([url isFileURL] == YES) {
            AddLocalFileTree(newItems, url);
        }
    }
    if ([newItems count] == 0) {
        NSArray* paths = [pasteboard propertyListForType:@"NSFilenamesPboardType"];
        for (NSString* path in paths) {
            AddLocalFileTree(newItems, [NSURL fileURLWithPath:path]);
        }
    }

    pthread_mutex_lock(&_lock);
    NSMutableArray* items = LocalFileItems();
    [items removeAllObjects];
    [items addObjectsFromArray:newItems];
    int count = (int)[items count];
    pthread_mutex_unlock(&_lock);

    if (itemCount != NULL) {
        *itemCount = count;
    }

    return count > 0;
}

bool ClipboardManager::BuildFileList(char** fileListData, int* fileListLen) {
    if (fileListData == NULL || fileListLen == NULL) {
        return false;
    }

    *fileListData = NULL;
    *fileListLen = 0;

    NSArray* itemsSnapshot = nil;
    pthread_mutex_lock(&_lock);
    itemsSnapshot = [NSArray arrayWithArray:LocalFileItems()];
    pthread_mutex_unlock(&_lock);

    int itemCount = (int)[itemsSnapshot count];
    int dataLen = 4 + (itemCount * CLIPRDR_FILEDESCRIPTOR_SIZE);
    if (itemCount <= 0 || dataLen > MAX_CLIPBOARD_DATA_SIZE) {
        return false;
    }

    xstream_t* stream = xstream_create(dataLen);
    if (stream == NULL) {
        return false;
    }

    xstream_writeInt32(stream, itemCount);
    for (NSDictionary* item in itemsSnapshot) {
        BOOL isDir = [[item objectForKey:@"isDir"] boolValue];
        uint64_t fileSize = [[item objectForKey:@"size"] unsignedLongLongValue];
        uint64_t fileTime = [[item objectForKey:@"mtime"] unsignedLongLongValue];
        unsigned char zero32[32] = {0,};
        unsigned char zero16[16] = {0,};

        xstream_writeInt32(stream, FD_ATTRIBUTES | FD_WRITESTIME | FD_FILESIZE | FD_SHOWPROGRESSUI);
        xstream_writeData(stream, zero32, sizeof(zero32));
        xstream_writeInt32(stream, isDir ? FILE_ATTRIBUTE_DIRECTORY : FILE_ATTRIBUTE_NORMAL);
        xstream_writeData(stream, zero16, sizeof(zero16));
        xstream_writeInt32(stream, (int)(fileTime & 0xFFFFFFFF));
        xstream_writeInt32(stream, (int)((fileTime >> 32) & 0xFFFFFFFF));
        xstream_writeInt32(stream, (int)((fileSize >> 32) & 0xFFFFFFFF));
        xstream_writeInt32(stream, (int)(fileSize & 0xFFFFFFFF));
        WriteFileName(stream, [item objectForKey:@"name"]);
    }

    int bufferLen = 0;
    const void* buffer = xstream_get_raw_buffer(stream, &bufferLen);
    if (buffer == NULL || bufferLen != dataLen) {
        xstream_free(stream);
        return false;
    }

    char* result = (char*)malloc(bufferLen);
    if (result == NULL) {
        xstream_free(stream);
        return false;
    }

    memcpy(result, buffer, bufferLen);
    xstream_free(stream);

    *fileListData = result;
    *fileListLen = bufferLen;
    return true;
}

bool ClipboardManager::ParseRemoteFileList(const void* data, int dataLen) {
    if (data == NULL || dataLen < 4) {
        return false;
    }

    const unsigned char* bytes = (const unsigned char*)data;
    int itemCount = (int)((uint32_t)bytes[0] |
                          ((uint32_t)bytes[1] << 8) |
                          ((uint32_t)bytes[2] << 16) |
                          ((uint32_t)bytes[3] << 24));
    if (itemCount <= 0 || itemCount > 65536 || dataLen < 4 + itemCount * CLIPRDR_FILEDESCRIPTOR_SIZE) {
        return false;
    }

    NSMutableArray* newItems = [NSMutableArray array];
    int offset = 4;
    for (int i = 0; i < itemCount; i++) {
        const unsigned char* descriptor = bytes + offset;
        int attributesOffset = 4 + 32;
        int fileTimeOffset = attributesOffset + 4 + 16;
        int fileSizeOffset = fileTimeOffset + 8;
        int nameOffset = fileSizeOffset + 8;

        int attributes = (int)((uint32_t)descriptor[attributesOffset] |
                               ((uint32_t)descriptor[attributesOffset + 1] << 8) |
                               ((uint32_t)descriptor[attributesOffset + 2] << 16) |
                               ((uint32_t)descriptor[attributesOffset + 3] << 24));
        uint64_t fileSizeHigh = (uint32_t)descriptor[fileSizeOffset] |
                                ((uint32_t)descriptor[fileSizeOffset + 1] << 8) |
                                ((uint32_t)descriptor[fileSizeOffset + 2] << 16) |
                                ((uint32_t)descriptor[fileSizeOffset + 3] << 24);
        uint64_t fileSizeLow = (uint32_t)descriptor[fileSizeOffset + 4] |
                               ((uint32_t)descriptor[fileSizeOffset + 5] << 8) |
                               ((uint32_t)descriptor[fileSizeOffset + 6] << 16) |
                               ((uint32_t)descriptor[fileSizeOffset + 7] << 24);
        NSString* fileName = ReadFileDescriptorName(descriptor + nameOffset, 520);
        if (IsSafeRelativeFileName(fileName)) {
            BOOL isDir = (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
            NSDictionary* item = [NSDictionary dictionaryWithObjectsAndKeys:
                                  fileName, @"name",
                                  [NSNumber numberWithBool:isDir], @"isDir",
                                  [NSNumber numberWithUnsignedLongLong:(isDir ? 0 : ((fileSizeHigh << 32) | fileSizeLow))], @"size",
                                  [NSNumber numberWithInt:i], @"lindex",
                                  nil];
            [newItems addObject:item];
        }

        offset += CLIPRDR_FILEDESCRIPTOR_SIZE;
    }

    pthread_mutex_lock(&_lock);
    NSMutableArray* items = RemoteFileItems(_remoteFileItems);
    [items removeAllObjects];
    [items addObjectsFromArray:newItems];
    _remoteFileClipboardReady = [items count] > 0 ? 1 : 0;
    pthread_mutex_unlock(&_lock);

    return [newItems count] > 0;
}

void ClipboardManager::BeginRemoteFileCopyToFolder(NSURL* folderUrl) {
    if (CheckWritableFolder(folderUrl) == false) {
        UnlockRemoteFileCopy();
        pthread_mutex_lock(&_lock);
        _fileCopyChoosingFolder = 0;
        pthread_mutex_unlock(&_lock);
        ShowFileCopyAlert(NSLocalizedString(@"filecopy.alert.permission", nil));
        return;
    }

    if (PrepareRemoteFileDestinations(folderUrl) == false) {
        UnlockRemoteFileCopy();
        pthread_mutex_lock(&_lock);
        _fileCopyChoosingFolder = 0;
        pthread_mutex_unlock(&_lock);
        ShowFileCopyAlert(NSLocalizedString(@"filecopy.alert.failed", nil));
        return;
    }

    FileCopyWindow* window = [[FileCopyWindow alloc] init];
    window.cancelHandler = ^{
        CancelRemoteFileCopy();
    };

    pthread_mutex_lock(&_lock);
    _fileCopyChoosingFolder = 0;
    _fileCopyInProgress = 1;
    _fileCopyCancelled = 0;
    _fileCopyCurrentItemIndex = 0;
    _fileCopyExpectedStreamId = 0;
    _fileCopyCurrentLindex = 0;
    _fileCopyCurrentOffset = 0;
    _fileCopyTransferredBytes = 0;
    if (_fileCopyWindow != NULL) {
        CFRelease(_fileCopyWindow);
    }
    _fileCopyWindow = (__bridge_retained void*)window;
    pthread_mutex_unlock(&_lock);

    [window showWindow];
    StartNextRemoteFileItem();
}

void ClipboardManager::StartNextRemoteFileItem() {
    @autoreleasepool {
        while (1) {
            pthread_mutex_lock(&_lock);
            bool cancelled = _fileCopyCancelled != 0;
            xipc_t* client = _client;
            NSMutableArray* items = RemoteFileItems(_remoteFileItems);
            int itemIndex = _fileCopyCurrentItemIndex;
            pthread_mutex_unlock(&_lock);

            if (cancelled || client == NULL) {
                FinishRemoteFileCopy(false);
                return;
            }

            if (itemIndex >= (int)[items count]) {
                FinishRemoteFileCopy(true);
                return;
            }

            NSDictionary* item = [items objectAtIndex:itemIndex];
            NSString* fileName = [item objectForKey:@"name"];
            NSString* targetPath = [item objectForKey:@"targetPath"];
            BOOL isDir = [[item objectForKey:@"isDir"] boolValue];
            uint64_t fileSize = [[item objectForKey:@"size"] unsignedLongLongValue];

            UpdateFileCopyWindow(fileName);

            NSError* error = nil;
            if (isDir) {
                [[NSFileManager defaultManager] createDirectoryAtPath:targetPath withIntermediateDirectories:YES attributes:nil error:&error];
                if (error != nil) {
                    FinishRemoteFileCopy(false);
                    return;
                }

                pthread_mutex_lock(&_lock);
                _fileCopyCurrentItemIndex++;
                pthread_mutex_unlock(&_lock);
                continue;
            }

            NSString* parentPath = [targetPath stringByDeletingLastPathComponent];
            [[NSFileManager defaultManager] createDirectoryAtPath:parentPath withIntermediateDirectories:YES attributes:nil error:&error];
            if (error != nil || [[NSFileManager defaultManager] createFileAtPath:targetPath contents:nil attributes:nil] == NO) {
                FinishRemoteFileCopy(false);
                return;
            }

            NSFileHandle* handle = [NSFileHandle fileHandleForWritingAtPath:targetPath];
            if (handle == nil) {
                FinishRemoteFileCopy(false);
                return;
            }

            pthread_mutex_lock(&_lock);
            if (_fileCopyCurrentHandle != NULL) {
                CFRelease(_fileCopyCurrentHandle);
            }
            if (_fileCopyCurrentPath != NULL) {
                CFRelease(_fileCopyCurrentPath);
            }
            _fileCopyCurrentHandle = (__bridge_retained void*)handle;
            _fileCopyCurrentPath = (__bridge_retained void*)targetPath;
            _fileCopyCurrentLindex = [[item objectForKey:@"lindex"] intValue];
            _fileCopyCurrentOffset = 0;
            pthread_mutex_unlock(&_lock);

            if (fileSize == 0) {
                [handle closeFile];
                pthread_mutex_lock(&_lock);
                CFRelease(_fileCopyCurrentHandle);
                CFRelease(_fileCopyCurrentPath);
                _fileCopyCurrentHandle = NULL;
                _fileCopyCurrentPath = NULL;
                _fileCopyCurrentItemIndex++;
                pthread_mutex_unlock(&_lock);
                continue;
            }

            RequestCurrentRemoteFileChunk();
            return;
        }
    }
}

void ClipboardManager::RequestCurrentRemoteFileChunk() {
    pthread_mutex_lock(&_lock);
    xipc_t* client = _client;
    NSMutableArray* items = RemoteFileItems(_remoteFileItems);
    int itemIndex = _fileCopyCurrentItemIndex;
    int lindex = _fileCopyCurrentLindex;
    uint64_t offset = _fileCopyCurrentOffset;
    int clipDataId = _fileCopyClipDataId;
    int streamId = _fileCopyStreamId++;
    _fileCopyExpectedStreamId = streamId;
    uint64_t fileSize = 0;
    if (itemIndex >= 0 && itemIndex < (int)[items count]) {
        fileSize = [[[items objectAtIndex:itemIndex] objectForKey:@"size"] unsignedLongLongValue];
    }
    pthread_mutex_unlock(&_lock);

    if (client == NULL || fileSize <= offset) {
        FinishRemoteFileCopy(false);
        return;
    }

    uint64_t remaining = fileSize - offset;
    int requested = remaining > REMOTE_FILE_COPY_CHUNK_SIZE ? REMOTE_FILE_COPY_CHUNK_SIZE : (int)remaining;
    SendFileContentsRequest(client, streamId, lindex, FILECONTENTS_RANGE, offset, requested, clipDataId);
}

void ClipboardManager::HandleFileContentsResponse(xstream_t* clipStream, int msgFlags, int msgLen) {
    if ((msgFlags & CB_RESPONSE_FAIL) != 0 || (msgFlags & CB_RESPONSE_OK) == 0 || msgLen < 4) {
        FinishRemoteFileCopy(false);
        return;
    }

    int streamId = xstream_readInt32(clipStream);
    int dataLen = msgLen - 4;
    const void* data = xstream_readData(clipStream, dataLen);

    pthread_mutex_lock(&_lock);
    bool valid = _fileCopyInProgress != 0 && _fileCopyExpectedStreamId == streamId && _fileCopyCancelled == 0;
    NSFileHandle* handle = FileCopyCurrentHandle(_fileCopyCurrentHandle);
    NSMutableArray* items = RemoteFileItems(_remoteFileItems);
    int itemIndex = _fileCopyCurrentItemIndex;
    pthread_mutex_unlock(&_lock);

    if (valid == false || handle == nil || (data == NULL && dataLen > 0)) {
        return;
    }

    @try {
        if (dataLen > 0) {
            NSData* fileData = [NSData dataWithBytes:data length:dataLen];
            [handle writeData:fileData];
        }
    } @catch (...) {
        FinishRemoteFileCopy(false);
        return;
    }

    pthread_mutex_lock(&_lock);
    _fileCopyCurrentOffset += dataLen;
    _fileCopyTransferredBytes += dataLen;
    uint64_t offset = _fileCopyCurrentOffset;
    uint64_t fileSize = 0;
    NSString* fileName = nil;
    if (itemIndex >= 0 && itemIndex < (int)[items count]) {
        NSDictionary* item = [items objectAtIndex:itemIndex];
        fileSize = [[item objectForKey:@"size"] unsignedLongLongValue];
        fileName = [item objectForKey:@"name"];
    }
    pthread_mutex_unlock(&_lock);

    UpdateFileCopyWindow(fileName);

    if (offset >= fileSize) {
        [handle closeFile];
        pthread_mutex_lock(&_lock);
        if (_fileCopyCurrentHandle != NULL) {
            CFRelease(_fileCopyCurrentHandle);
            _fileCopyCurrentHandle = NULL;
        }
        if (_fileCopyCurrentPath != NULL) {
            CFRelease(_fileCopyCurrentPath);
            _fileCopyCurrentPath = NULL;
        }
        _fileCopyCurrentItemIndex++;
        pthread_mutex_unlock(&_lock);
        StartNextRemoteFileItem();
        return;
    }

    RequestCurrentRemoteFileChunk();
}

void ClipboardManager::FinishRemoteFileCopy(bool success) {
    UnlockRemoteFileCopy();
    pthread_mutex_lock(&_lock);
    bool cancelled = _fileCopyCancelled != 0;
    NSFileHandle* handle = FileCopyCurrentHandle(_fileCopyCurrentHandle);
    NSString* incompletePath = FileCopyCurrentPath(_fileCopyCurrentPath);
    FileCopyWindow* window = FileCopyProgressWindow(_fileCopyWindow);

    if (handle != nil) {
        CFRetain((__bridge CFTypeRef)handle);
    }
    if (incompletePath != nil) {
        CFRetain((__bridge CFTypeRef)incompletePath);
    }
    if (window != nil) {
        CFRetain((__bridge CFTypeRef)window);
    }

    _fileCopyInProgress = 0;
    _fileCopyChoosingFolder = 0;
    _fileCopyCancelled = 0;
    _fileCopyExpectedStreamId = 0;
    _fileCopyCurrentItemIndex = 0;
    _fileCopyCurrentOffset = 0;
    _fileCopyTransferredBytes = 0;

    if (_fileCopyCurrentHandle != NULL) {
        CFRelease(_fileCopyCurrentHandle);
        _fileCopyCurrentHandle = NULL;
    }
    if (_fileCopyCurrentPath != NULL) {
        CFRelease(_fileCopyCurrentPath);
        _fileCopyCurrentPath = NULL;
    }
    if (_fileCopyWindow != NULL) {
        CFRelease(_fileCopyWindow);
        _fileCopyWindow = NULL;
    }
    pthread_mutex_unlock(&_lock);

    if (handle != nil) {
        @try {
            [handle closeFile];
        } @catch (...) {
        }
    }
    if (success == false && incompletePath != nil) {
        [[NSFileManager defaultManager] removeItemAtPath:incompletePath error:nil];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [window closeWindow];
        if (success == false && cancelled == false) {
            ShowFileCopyAlert(NSLocalizedString(@"filecopy.alert.failed", nil));
        }
        if (window != nil) {
            CFRelease((__bridge CFTypeRef)window);
        }
    });

    if (handle != nil) {
        CFRelease((__bridge CFTypeRef)handle);
    }
    if (incompletePath != nil) {
        CFRelease((__bridge CFTypeRef)incompletePath);
    }
}

void ClipboardManager::CancelRemoteFileCopy() {
    pthread_mutex_lock(&_lock);
    _fileCopyCancelled = 1;
    pthread_mutex_unlock(&_lock);
    FinishRemoteFileCopy(false);
}

void ClipboardManager::UnlockRemoteFileCopy() {
    pthread_mutex_lock(&_lock);
    xipc_t* client = _client;
    int clipDataId = _fileCopyClipDataId;
    _fileCopyClipDataId = 0;
    pthread_mutex_unlock(&_lock);

    if (clipDataId != 0) {
        SendClipboardDataId(client, CB_UNLOCK_CLIPDATA, clipDataId);
    }
}

bool ClipboardManager::PrepareRemoteFileDestinations(NSURL* folderUrl) {
    if (folderUrl == nil) {
        return false;
    }

    pthread_mutex_lock(&_lock);
    NSArray* snapshot = [NSArray arrayWithArray:RemoteFileItems(_remoteFileItems)];
    pthread_mutex_unlock(&_lock);

    NSMutableDictionary* rootMap = [NSMutableDictionary dictionary];
    NSMutableArray* preparedItems = [NSMutableArray array];
    for (NSDictionary* item in snapshot) {
        NSString* name = [item objectForKey:@"name"];
        
        // NFD --> NFC (윈도우에서의 자소 분리 해결)
        NSString* normalizedName = [name stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
        NSArray* components = [normalizedName componentsSeparatedByString:@"/"];
        if ([components count] == 0) {
            return false;
        }

        NSString* root = [components objectAtIndex:0];
        NSString* mappedRoot = [rootMap objectForKey:root];
        if (mappedRoot == nil) {
            NSURL* uniqueUrl = MakeUniqueChildUrl(folderUrl, root);
            if (uniqueUrl == nil) {
                return false;
            }
            mappedRoot = [uniqueUrl lastPathComponent];
            [rootMap setObject:mappedRoot forKey:root];
        }

        NSString* relativePath = mappedRoot;
        for (NSUInteger i = 1; i < [components count]; i++) {
            relativePath = [relativePath stringByAppendingPathComponent:[components objectAtIndex:i]];
        }

        NSString* targetPath = [[folderUrl path] stringByAppendingPathComponent:relativePath];
        NSMutableDictionary* preparedItem = [NSMutableDictionary dictionaryWithDictionary:item];
        [preparedItem setObject:targetPath forKey:@"targetPath"];
        [preparedItems addObject:preparedItem];
    }

    uint64_t totalBytes = 0;
    for (NSDictionary* item in preparedItems) {
        if ([[item objectForKey:@"isDir"] boolValue] == NO) {
            totalBytes += [[item objectForKey:@"size"] unsignedLongLongValue];
        }
    }

    pthread_mutex_lock(&_lock);
    NSMutableArray* items = RemoteFileItems(_remoteFileItems);
    [items removeAllObjects];
    [items addObjectsFromArray:preparedItems];
    _fileCopyTotalBytes = totalBytes;
    pthread_mutex_unlock(&_lock);
    return true;
}

bool ClipboardManager::CheckWritableFolder(NSURL* folderUrl) {
    if (folderUrl == nil || [folderUrl isFileURL] == NO) {
        return false;
    }

    NSString* testName = [NSString stringWithFormat:@".osxrdp-write-test-%@", [[NSUUID UUID] UUIDString]];
    NSURL* testUrl = [folderUrl URLByAppendingPathComponent:testName];
    NSData* data = [NSData data];
    BOOL result = [data writeToURL:testUrl atomically:NO];
    if (result == YES) {
        [[NSFileManager defaultManager] removeItemAtURL:testUrl error:nil];
    }
    return result == YES;
}

void ClipboardManager::ShowFileCopyAlert(NSString* message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert* alert = [[NSAlert alloc] init];
        [alert setMessageText:NSLocalizedString(@"filecopy.alert.title", nil)];
        [alert setInformativeText:message != nil ? message : @""];
        [alert addButtonWithTitle:NSLocalizedString(@"permission.button.ok", nil)];
        [alert runModal];
    });
}

void ClipboardManager::UpdateFileCopyWindow(NSString* fileName) {
    pthread_mutex_lock(&_lock);
    FileCopyWindow* window = FileCopyProgressWindow(_fileCopyWindow);
    uint64_t transferred = _fileCopyTransferredBytes;
    uint64_t total = _fileCopyTotalBytes;
    pthread_mutex_unlock(&_lock);

    dispatch_async(dispatch_get_main_queue(), ^{
        [window updateFileName:fileName transferredBytes:transferred totalBytes:total];
    });
}

bool ClipboardManager::GetPasteboardText(char** utf8Text, int* utf8Len, int* changeCount) {
    if (changeCount == NULL) {
        return false;
    }

    *changeCount = 0;

    NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
    if (pasteboard == nil) {
        return false;
    }

    *changeCount = (int)[pasteboard changeCount];

    if (utf8Text != NULL && utf8Len != NULL) {
        *utf8Text = NULL;
        *utf8Len = 0;

        NSString* text = [pasteboard stringForType:NSPasteboardTypeString];
        if (text == nil || [text length] == 0) {
            return true;
        }

        NSData* textData = [text dataUsingEncoding:NSUTF8StringEncoding];
        if (textData == nil) {
            return false;
        }

        int dataLen = (int)[textData length];
        char* buffer = (char*)malloc(dataLen);
        if (buffer == NULL) {
            return false;
        }

        if (dataLen > 0) {
            memcpy(buffer, [textData bytes], dataLen);
        }

        *utf8Text = buffer;
        *utf8Len = dataLen;
    }

    return true;
}

bool ClipboardManager::GetPasteboardRtf(char** rtfData, int* rtfLen) {
    if (rtfData == NULL || rtfLen == NULL) {
        return false;
    }

    *rtfData = NULL;
    *rtfLen = 0;

    NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
    if (pasteboard == nil) {
        return false;
    }

    NSData* data = [pasteboard dataForType:NSPasteboardTypeRTF];
    if (data == nil || [data length] <= 0) {
        return false;
    }

    int dataLen = (int)[data length];
    char* buffer = (char*)malloc(dataLen);
    if (buffer == NULL) {
        return false;
    }

    memcpy(buffer, [data bytes], dataLen);
    *rtfData = buffer;
    *rtfLen = dataLen;
    return true;
}

bool ClipboardManager::GetPasteboardImage(char** dibData, int* dibLen) {
    if (dibData == NULL || dibLen == NULL) {
        return false;
    }

    *dibData = NULL;
    *dibLen = 0;

    NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
    if (pasteboard == nil) {
        return false;
    }

    NSImage* image = [[NSImage alloc] initWithPasteboard:pasteboard];
    if (image == nil) {
        return false;
    }

    return BuildDibFromImage(image, dibData, dibLen);
}

bool ClipboardManager::BuildWindowsText(const char* utf8Text, int utf8Len, int formatId, char** outData, int* outDataLen) {
    if (utf8Text == NULL || utf8Len < 0 || outData == NULL || outDataLen == NULL) {
        return false;
    }

    if (formatId != CF_UNICODETEXT) {
        return false;
    }

    *outData = NULL;
    *outDataLen = 0;

    NSString* text = [[NSString alloc] initWithBytes:utf8Text length:utf8Len encoding:NSUTF8StringEncoding];
    if (text == nil) {
        return false;
    }

    NSMutableString* normalizedText = [NSMutableString stringWithString:text];
    [normalizedText replaceOccurrencesOfString:@"\r\n"
                                    withString:@"\n"
                                       options:0
                                         range:NSMakeRange(0, [normalizedText length])];
    [normalizedText replaceOccurrencesOfString:@"\r"
                                    withString:@"\n"
                                       options:0
                                         range:NSMakeRange(0, [normalizedText length])];
    [normalizedText replaceOccurrencesOfString:@"\n"
                                    withString:@"\r\n"
                                       options:0
                                         range:NSMakeRange(0, [normalizedText length])];

    NSData* utf16Data = [normalizedText dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
    if (utf16Data == nil) {
        return false;
    }

    int dataLen = (int)[utf16Data length];
    char* buffer = (char*)malloc(dataLen + 2);
    if (buffer == NULL) {
        return false;
    }

    if (dataLen > 0) {
        memcpy(buffer, [utf16Data bytes], dataLen);
    }
    buffer[dataLen] = 0;
    buffer[dataLen + 1] = 0;

    *outData = buffer;
    *outDataLen = dataLen + 2;
    return true;
}

bool ClipboardManager::SetTextToPasteboard(const void* data, int dataLen, int formatId) {
    if ((data == NULL && dataLen > 0) || dataLen < 0) {
        return false;
    }

    if (formatId != CF_UNICODETEXT) {
        return false;
    }

    int textLen = 0;
    const unsigned char* bytes = (const unsigned char*)data;

    while (textLen + 1 < dataLen) {
        if (bytes[textLen] == 0 && bytes[textLen + 1] == 0) {
            break;
        }

        textLen += 2;
    }

    NSData* textData = [NSData dataWithBytes:data length:textLen];
    NSString* text = [[NSString alloc] initWithData:textData encoding:NSUTF16LittleEndianStringEncoding];
    if (text == nil) {
        return false;
    }

    NSMutableString* normalizedText = [NSMutableString stringWithString:text];
    [normalizedText replaceOccurrencesOfString:@"\r\n"
                                    withString:@"\n"
                                       options:0
                                         range:NSMakeRange(0, [normalizedText length])];
    [normalizedText replaceOccurrencesOfString:@"\r"
                                    withString:@"\n"
                                       options:0
                                         range:NSMakeRange(0, [normalizedText length])];

    NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    BOOL result = [pasteboard setString:normalizedText forType:NSPasteboardTypeString];

    if (result == YES) {
        pthread_mutex_lock(&_lock);
        _lastChangeCount = (int)[pasteboard changeCount];
        pthread_mutex_unlock(&_lock);
    }

    return result == YES;
}

bool ClipboardManager::SetRtfToPasteboard(const void* data, int dataLen) {
    if ((data == NULL && dataLen > 0) || dataLen < 0) {
        return false;
    }

    NSData* rtfData = [NSData dataWithBytes:data length:dataLen];
    if (rtfData == nil) {
        return false;
    }

    NSAttributedString* attributedText = [[NSAttributedString alloc] initWithRTF:rtfData documentAttributes:NULL];
    NSString* plainText = nil;
    if (attributedText != nil) {
        plainText = [attributedText string];
    }

    NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
    NSMutableArray* types = [NSMutableArray arrayWithObject:NSPasteboardTypeRTF];
    if (plainText != nil && [plainText length] > 0) {
        [types addObject:NSPasteboardTypeString];
    }

    [pasteboard declareTypes:types owner:nil];
    BOOL result = [pasteboard setData:rtfData forType:NSPasteboardTypeRTF];
    if (result == YES && plainText != nil && [plainText length] > 0) {
        [pasteboard setString:plainText forType:NSPasteboardTypeString];
    }

    if (result == YES) {
        pthread_mutex_lock(&_lock);
        _lastChangeCount = (int)[pasteboard changeCount];
        pthread_mutex_unlock(&_lock);
    }

    return result == YES;
}

bool ClipboardManager::SetImageToPasteboard(const void* data, int dataLen) {
    char* bmpData = NULL;
    int bmpLen = 0;

    if (BuildBmpFromDibData(data, dataLen, &bmpData, &bmpLen) == false || bmpData == NULL || bmpLen <= 0) {
        return false;
    }

    NSData* imageData = [NSData dataWithBytesNoCopy:bmpData length:bmpLen freeWhenDone:YES];
    if (imageData == nil) {
        free(bmpData);
        return false;
    }

    NSImage* image = [[NSImage alloc] initWithData:imageData];
    if (image == nil) {
        return false;
    }

    NSData* tiffData = [image TIFFRepresentation];
    if (tiffData == nil) {
        return false;
    }

    NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard declareTypes:[NSArray arrayWithObject:NSPasteboardTypeTIFF] owner:nil];
    BOOL result = [pasteboard setData:tiffData forType:NSPasteboardTypeTIFF];

    if (result == YES) {
        pthread_mutex_lock(&_lock);
        _lastChangeCount = (int)[pasteboard changeCount];
        pthread_mutex_unlock(&_lock);
    }

    return result == YES;
}
