#include "ClipboardManager.h"

#import <AppKit/AppKit.h>
#include "osxrdp/packet.h"
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

static const int CB_RESPONSE_OK = 0x0001;
static const int CB_RESPONSE_FAIL = 0x0002;
static const int CB_ASCII_NAMES = 0x0004;

static const int CF_TEXT = 1;
static const int CF_UNICODETEXT = 13;
static const int CF_LOCALE = 16;
static const int CF_OEMTEXT = 7;

// 클립보드 모니터링 주기
static const useconds_t CLIPBOARD_MONITOR_INTERVAL_US = 500000;

// 한번에 전송할 클립보드 데이터의 크기 (바이트)
static const int IPC_CLIPBOARD_CHUNK_SIZE = 14 * 1024;
static const int INVALID_CHANGE_COUNT = -1;

ClipboardManager::ClipboardManager()
: _clipDataBuffer(NULL)
, _clipDataBufferSize(0)
, _clipDataBufferCurrentLen(0)
, _pendingClipType(PendingClipType_None)
, _monitorThreadRunning(0)
, _monitorStopRequested(0)
, _client(NULL)
, _lastChangeCount(INVALID_CHANGE_COUNT) {
    pthread_mutex_init(&_lock, NULL);

    NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
    if (pasteboard != nil) {
        _lastChangeCount = (int)[pasteboard changeCount];
    }

    // 클립보드 모니터링 스레드
    if (pthread_create(&_monitorThread, NULL, MonitorThreadEntry, this) == 0) {
        _monitorThreadRunning = 1;
    }
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
    pthread_mutex_destroy(&_lock);
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

    int channelId = xstream_readInt32(cmd);
    int channelFlags = xstream_readInt32(cmd);
    int totalLen = xstream_readInt32(cmd);
    int dataLen = xstream_readInt32(cmd);
    const void* data = xstream_readData(cmd, dataLen);

    if (channelId < 0 || totalLen <= 0 || dataLen < 0 || data == NULL) {
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
    xstream_t* clipStream = xstream_create_for_read((void*)data, dataLen);
    if (clipStream == NULL) {
        return;
    }

    if (xstream_getRemaining(clipStream) < 8) {
        xstream_free(clipStream);
        return;
    }

    int msgType = xstream_readInt16(clipStream);
    int msgFlags = xstream_readInt16(clipStream);
    int msgLen = xstream_readInt32(clipStream);
    int remaining = xstream_getRemaining(clipStream);

    if (msgLen < 0 || msgLen > remaining) {
        xstream_free(clipStream);
        return;
    }

    switch (msgType) {
        case CB_MONITOR_READY:
            HandleMonitorReady(client);
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
        default:
            break;
    }

    xstream_free(clipStream);
}

void ClipboardManager::HandleMonitorReady(xipc_t* client) {
    UpdateRemoteClipboardContext(client);
}

void ClipboardManager::HandleFormatList(xipc_t* client, xstream_t* clipStream, int msgFlags, int msgLen) {
    int formatId = FindRequestedFormatId(msgFlags, msgLen, clipStream);

    SendFormatAck(client, true);

    if (formatId == 0) {
        _pendingClipType = PendingClipType_None;
        return;
    }

    _pendingClipType = PendingClipType_Text;

    SendDataRequest(client, formatId);
}

void ClipboardManager::HandleDataRequest(xipc_t* client, xstream_t* clipStream, int msgFlags, int msgLen) {
    (void)msgFlags;

    if (msgLen < 4) {
        SendDataResponseFailed(client);
        return;
    }

    int requestedFormatId = xstream_readInt32(clipStream);
    if (requestedFormatId != CF_UNICODETEXT &&
        requestedFormatId != CF_TEXT &&
        requestedFormatId != CF_OEMTEXT) {
        SendDataResponseFailed(client);
        return;
    }

    char* utf8Text = NULL;
    int utf8Len = 0;
    int changeCount = 0;

    if (GetPasteboardText(&utf8Text, &utf8Len, &changeCount) == false || utf8Text == NULL) {
        SendDataResponseFailed(client);
        return;
    }

    SendDataResponseText(client, utf8Text, utf8Len);
    free(utf8Text);
}

void ClipboardManager::HandleDataResponse(xstream_t* clipStream, int msgFlags, int msgLen) {
    if (_pendingClipType == PendingClipType_None) {
        return;
    }

    if ((msgFlags & CB_RESPONSE_FAIL) != 0 || (msgFlags & CB_RESPONSE_OK) == 0) {
        _pendingClipType = PendingClipType_None;
        return;
    }

    const void* data = xstream_readData(clipStream, msgLen);
    if (data == NULL && msgLen > 0) {
        _pendingClipType = PendingClipType_None;
        return;
    }

    if (_pendingClipType == PendingClipType_Text) {
        SetTextToPasteboard(data, msgLen);
    }

    _pendingClipType = PendingClipType_None;
}

int ClipboardManager::FindRequestedFormatId(int msgFlags, int msgLen, xstream_t* clipStream) {
    if ((msgFlags & CB_ASCII_NAMES) != 0) {
        return FindRequestedFormatIdShortName(clipStream, msgLen);
    }

    if (msgLen > 0 && msgLen % 36 == 0) {
        int formatId = FindRequestedFormatIdShortName(clipStream, msgLen);
        if (formatId != 0) {
            return formatId;
        }

        xstream_resetPos(clipStream);
        xstream_readInt16(clipStream);
        xstream_readInt16(clipStream);
        xstream_readInt32(clipStream);
    }

    return FindRequestedFormatIdLongName(clipStream, msgLen);
}

int ClipboardManager::FindRequestedFormatIdLongName(xstream_t* clipStream, int msgLen) {
    int readLen = 0;
    bool hasTextFormat = false;

    while (readLen + 4 <= msgLen) {
        int formatId = xstream_readInt32(clipStream);
        readLen += 4;

        if (formatId == CF_UNICODETEXT || formatId == CF_TEXT || formatId == CF_OEMTEXT) {
            hasTextFormat = true;
        }

        bool foundTerminator = false;
        while (readLen + 2 <= msgLen) {
            int ch = xstream_readInt16(clipStream);
            readLen += 2;

            if (ch == 0) {
                foundTerminator = true;
                break;
            }
        }

        if (foundTerminator == false) {
            return 0;
        }
    }

    if (hasTextFormat) {
        return CF_UNICODETEXT;
    }

    return 0;
}

int ClipboardManager::FindRequestedFormatIdShortName(xstream_t* clipStream, int msgLen) {
    int readLen = 0;
    bool hasTextFormat = false;

    while (readLen + 36 <= msgLen) {
        int formatId = xstream_readInt32(clipStream);
        const void* dummy = xstream_readData(clipStream, 32);
        if (dummy == NULL) {
            return 0;
        }

        readLen += 36;

        if (formatId == CF_UNICODETEXT || formatId == CF_TEXT || formatId == CF_OEMTEXT) {
            hasTextFormat = true;
        }
    }

    if (readLen != msgLen) {
        return 0;
    }

    if (hasTextFormat) {
        return CF_UNICODETEXT;
    }

    return 0;
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
    xstream_t* clipStream = xstream_create(8);
    if (clipStream == NULL) {
        return;
    }

    xstream_writeInt16(clipStream, CB_FORMAT_LIST_RESPONSE);
    xstream_writeInt16(clipStream, success ? CB_RESPONSE_OK : CB_RESPONSE_FAIL);
    xstream_writeInt32(clipStream, 0);

    int bufferLen = 0;
    const void* buffer = xstream_get_raw_buffer(clipStream, &bufferLen);
    SendChannelData(client, buffer, bufferLen);

    xstream_free(clipStream);
}

void ClipboardManager::SendFormatList(xipc_t* client) {
    xstream_t* clipStream = xstream_create(40);
    if (clipStream == NULL) {
        return;
    }

    xstream_writeInt16(clipStream, CB_FORMAT_LIST);
    xstream_writeInt16(clipStream, 0);
    xstream_writeInt32(clipStream, 24);

    xstream_writeInt32(clipStream, CF_UNICODETEXT);
    xstream_writeInt16(clipStream, 0);
    xstream_writeInt32(clipStream, CF_LOCALE);
    xstream_writeInt16(clipStream, 0);
    xstream_writeInt32(clipStream, CF_TEXT);
    xstream_writeInt16(clipStream, 0);
    xstream_writeInt32(clipStream, CF_OEMTEXT);
    xstream_writeInt16(clipStream, 0);
    xstream_writeInt32(clipStream, 0);

    int bufferLen = 0;
    const void* buffer = xstream_get_raw_buffer(clipStream, &bufferLen);
    SendChannelData(client, buffer, bufferLen);

    xstream_free(clipStream);
}

void ClipboardManager::SendDataRequest(xipc_t* client, int formatId) {
    xstream_t* clipStream = xstream_create(12);
    if (clipStream == NULL) {
        return;
    }

    xstream_writeInt16(clipStream, CB_FORMAT_DATA_REQUEST);
    xstream_writeInt16(clipStream, 0);
    xstream_writeInt32(clipStream, 4);
    xstream_writeInt32(clipStream, formatId);

    int bufferLen = 0;
    const void* buffer = xstream_get_raw_buffer(clipStream, &bufferLen);
    SendChannelData(client, buffer, bufferLen);

    xstream_free(clipStream);
}

void ClipboardManager::SendDataResponseText(xipc_t* client, const char* utf8Text, int utf8Len) {
    if (utf8Text == NULL || utf8Len < 0) {
        SendDataResponseFailed(client);
        return;
    }

    char* textData = NULL;
    int textDataLen = 0;
    if (BuildWindowsUnicodeText(utf8Text, utf8Len, &textData, &textDataLen) == false || textData == NULL) {
        SendDataResponseFailed(client);
        return;
    }

    xstream_t* clipStream = xstream_create(textDataLen + 12);
    if (clipStream == NULL) {
        free(textData);
        SendDataResponseFailed(client);
        return;
    }

    xstream_writeInt16(clipStream, CB_FORMAT_DATA_RESPONSE);
    xstream_writeInt16(clipStream, CB_RESPONSE_OK);
    xstream_writeInt32(clipStream, textDataLen);
    xstream_writeData(clipStream, textData, textDataLen);
    xstream_writeInt32(clipStream, 0);

    int bufferLen = 0;
    const void* buffer = xstream_get_raw_buffer(clipStream, &bufferLen);
    SendChannelData(client, buffer, bufferLen);

    xstream_free(clipStream);
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

void ClipboardManager::SendChannelData(xipc_t* client, const void* data, int dataLen) {
    if (client == NULL || data == NULL || dataLen <= 0) {
        return;
    }

    const char* rawData = (const char*)data;
    int offset = 0;

    while (offset < dataLen) {
        int chunkLen = dataLen - offset;
        if (chunkLen > IPC_CLIPBOARD_CHUNK_SIZE) {
            chunkLen = IPC_CLIPBOARD_CHUNK_SIZE;
        }

        int channelFlags = 0;
        if (offset == 0) {
            channelFlags |= XR_CHANNEL_FLAG_FIRST;
        }
        if (offset + chunkLen >= dataLen) {
            channelFlags |= XR_CHANNEL_FLAG_LAST;
        }

        xstream_t* stream = xstream_create(chunkLen + sizeof(int) * 5);
        if (stream == NULL) {
            return;
        }

        xstream_writeInt32(stream, OSXRDP_CMDTYPE_CLIPBOARD);
        xstream_writeInt32(stream, OSXRDP_PACKETTYPE_REP_SETCLIENTCLIP);
        xstream_writeInt32(stream, channelFlags);
        xstream_writeInt32(stream, dataLen);
        xstream_writeInt32(stream, chunkLen);
        xstream_writeData(stream, (void*)(rawData + offset), chunkLen);

        int bufferLen = 0;
        const void* buffer = xstream_get_raw_buffer(stream, &bufferLen);
        xipc_send_data(client, buffer, bufferLen);

        xstream_free(stream);
        offset += chunkLen;
    }
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

bool ClipboardManager::BuildWindowsUnicodeText(const char* utf8Text, int utf8Len, char** outData, int* outDataLen) {
    if (utf8Text == NULL || utf8Len < 0 || outData == NULL || outDataLen == NULL) {
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

bool ClipboardManager::SetTextToPasteboard(const void* data, int dataLen) {
    if (data == NULL && dataLen > 0) {
        return false;
    }

    int textLen = dataLen;
    const unsigned char* bytes = (const unsigned char*)data;

    while (textLen >= 2 && bytes[textLen - 1] == 0 && bytes[textLen - 2] == 0) {
        textLen -= 2;
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
