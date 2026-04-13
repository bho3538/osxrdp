#ifndef ClipboardManager_hpp
#define ClipboardManager_hpp

#include "ipc.h"
#include "xstream.h"
#include <pthread.h>

class ClipboardManager {
public:
    ClipboardManager();
    ~ClipboardManager();

    void HandleCommand(xipc_t* client, xstream_t* cmd);

private:
    enum PendingClipType {
        PendingClipType_None = 0,
        PendingClipType_Text,       // 일반 텍스트
        PendingClipType_RichText,   // 서식있는 텍스트
        PendingClipType_Image       // 이미지 (비트맵)
    };

    char* _clipDataBuffer;
    int _clipDataBufferSize;
    int _clipDataBufferCurrentLen;

    PendingClipType _pendingClipType;
    int _pendingTextFormatId;
    int _pendingTextRetryCount;
    xipc_t* _client;
    int _lastChangeCount;

    pthread_mutex_t _lock;
    pthread_t _monitorThread;
    int _monitorThreadRunning;
    int _monitorStopRequested;

    void ResetChannelBuffer();
    bool AssembleChannelData(int channelFlags, int totalLen, const void* data, int dataLen, const void** completeData, int* completeLen);
    void UpdateRemoteClipboardContext(xipc_t* client);
    static int GetRequestedFormatPriority(PendingClipType clipType, int formatId);

    void HandleClipData(xipc_t* client, const void* data, int dataLen);
    void HandleFormatList(xipc_t* client, xstream_t* clipStream, int msgFlags, int msgLen);
    void HandleDataRequest(xipc_t* client, xstream_t* clipStream, int msgFlags, int msgLen);
    void HandleDataResponse(xstream_t* clipStream, int msgFlags, int msgLen);

    void FindRequestedFormat(int msgFlags, int msgLen, xstream_t* clipStream, int* formatId, PendingClipType* clipType);
    void FindRequestedFormatLongName(xstream_t* clipStream, int msgLen, int* formatId, PendingClipType* clipType);
    void FindRequestedFormatShortName(xstream_t* clipStream, int msgLen, int* formatId, PendingClipType* clipType);

    static void* MonitorThreadEntry(void* arg);
    void MonitorClipboardLoop();
    void ProcessLocalClipboardChange(int forceSend);

    void SendFormatAck(xipc_t* client, bool success);
    void SendFormatList(xipc_t* client);
    void SendDataRequest(xipc_t* client, int formatId);
    void SendDataResponse(xipc_t* client, const void* data, int dataLen);
    void SendDataResponseText(xipc_t* client, const char* utf8Text, int utf8Len, int formatId);
    void SendDataResponseFailed(xipc_t* client);
    void SendChannelData(xipc_t* client, const void* data, int dataLen);
    void SendChannelDataParts(xipc_t* client, const void* header, int headerLen, const void* data, int dataLen, const void* footer, int footerLen);

    bool GetPasteboardText(char** utf8Text, int* utf8Len, int* changeCount);
    bool GetPasteboardRtf(char** rtfData, int* rtfLen);
    bool GetPasteboardImage(char** dibData, int* dibLen);
    bool BuildWindowsText(const char* utf8Text, int utf8Len, int formatId, char** outData, int* outDataLen);
    bool SetTextToPasteboard(const void* data, int dataLen, int formatId);
    bool SetRtfToPasteboard(const void* data, int dataLen);
    bool SetImageToPasteboard(const void* data, int dataLen);
};

#endif /* ClipboardManager_hpp */
