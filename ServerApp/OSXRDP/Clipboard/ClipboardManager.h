#ifndef ClipboardManager_hpp
#define ClipboardManager_hpp

#include "ipc.h"
#include "xstream.h"
#include <pthread.h>
#include <stdint.h>

#ifdef __OBJC__
@class NSDate;
@class NSMutableArray;
@class NSString;
@class NSURL;
#else
typedef void NSDate;
typedef void NSMutableArray;
typedef void NSString;
typedef void NSURL;
#endif

class ClipboardManager {
public:
    ClipboardManager();
    ~ClipboardManager();

    void HandleCommand(xipc_t* client, xstream_t* cmd);
    bool HasRemoteFiles();
    void StartRemoteFileCopy();

private:
    enum PendingClipType {
        PendingClipType_None = 0,
        PendingClipType_Text,       // 일반 텍스트
        PendingClipType_RichText,   // 서식있는 텍스트
        PendingClipType_Image,      // 이미지 (비트맵)
        PendingClipType_FileList
    };

    char* _clipDataBuffer;
    int _clipDataBufferSize;
    int _clipDataBufferCurrentLen;

    PendingClipType _pendingClipType;
    int _pendingTextFormatId;
    int _pendingTextRetryCount;
    xipc_t* _client;
    int _lastChangeCount;
    int _remoteFileClipEnabled;
    void* _localFileItems;
    void* _remoteFileItems;
    int _remoteFileGroupFormatId;
    int _remoteFileContentsFormatId;
    int _remoteFileClipboardReady;

    int _fileCopyInProgress;
    int _fileCopyChoosingFolder;
    int _fileCopyCancelled;
    int _fileCopyCurrentItemIndex;
    int _fileCopyStreamId;
    int _fileCopyExpectedStreamId;
    int _fileCopyCurrentLindex;
    uint64_t _fileCopyCurrentOffset;
    uint64_t _fileCopyTotalBytes;
    uint64_t _fileCopyTransferredBytes;
    void* _fileCopyWindow;
    void* _fileCopyCurrentHandle;
    void* _fileCopyCurrentPath;

    pthread_mutex_t _lock;
    pthread_t _monitorThread;
    int _monitorThreadRunning;
    int _monitorStopRequested;

    void ResetChannelBuffer();
    bool AssembleChannelData(int channelFlags, int totalLen, const void* data, int dataLen, const void** completeData, int* completeLen);
    void UpdateRemoteClipboardContext(xipc_t* client);
    static int GetRequestedFormatPriority(PendingClipType clipType, int formatId);

    void HandleClipData(xipc_t* client, const void* data, int dataLen);
    void HandleCaps(xstream_t* clipStream, int msgLen);
    void HandleFormatList(xipc_t* client, xstream_t* clipStream, int msgFlags, int msgLen);
    void HandleDataRequest(xipc_t* client, xstream_t* clipStream, int msgFlags, int msgLen);
    void HandleDataResponse(xstream_t* clipStream, int msgFlags, int msgLen);
    void HandleFileContentsRequest(xipc_t* client, xstream_t* clipStream, int msgFlags, int msgLen);
    void HandleFileContentsResponse(xstream_t* clipStream, int msgFlags, int msgLen);

    void FindRequestedFormat(int msgFlags, int msgLen, xstream_t* clipStream, int* formatId, PendingClipType* clipType);
    void FindRequestedFormatLongName(xstream_t* clipStream, int msgLen, int* formatId, PendingClipType* clipType);
    void FindRequestedFormatShortName(xstream_t* clipStream, int msgLen, int* formatId, PendingClipType* clipType);
    bool FindRemoteFileFormats(int msgFlags, int msgLen, xstream_t* clipStream, int* fileGroupFormatId, int* fileContentsFormatId);

    static void* MonitorThreadEntry(void* arg);
    void MonitorClipboardLoop();
    void ProcessLocalClipboardChange(int forceSend);

    void SendFormatAck(xipc_t* client, bool success);
    void SendFormatList(xipc_t* client);
    void SendDataRequest(xipc_t* client, int formatId);
    void SendDataResponse(xipc_t* client, const void* data, int dataLen);
    void SendDataResponseText(xipc_t* client, const char* utf8Text, int utf8Len, int formatId);
    void SendDataResponseFailed(xipc_t* client);
    void SendFileContentsRequest(xipc_t* client, int streamId, int lindex, int flags, uint64_t offset, int requested);
    void SendFileContentsResponse(xipc_t* client, int streamId, const void* data, int dataLen);
    void SendFileContentsResponseFailed(xipc_t* client, int streamId);
    void SendChannelData(xipc_t* client, const void* data, int dataLen);
    void SendChannelDataParts(xipc_t* client, const void* header, int headerLen, const void* data, int dataLen, const void* footer, int footerLen);

    NSMutableArray* LocalFileItems();
    static uint64_t ReadUInt64FromLowHigh(int low, int high);
    static void WriteUInt64ToBuffer(unsigned char* buffer, uint64_t value);
    static uint64_t FileTimeFromDate(NSDate* date);
    static void WriteFileName(xstream_t* stream, NSString* fileName);
    static void AddLocalFileItem(NSMutableArray* items, NSURL* url, NSString* name);
    static void AddLocalFileTree(NSMutableArray* items, NSURL* rootUrl);
    static NSString* ReadFileDescriptorName(const unsigned char* data, int dataLen);
    static NSURL* MakeUniqueChildUrl(NSURL* folderUrl, NSString* fileName);
    static bool IsSafeRelativeFileName(NSString* fileName);

    bool ParseRemoteFileList(const void* data, int dataLen);
    void BeginRemoteFileCopyToFolder(NSURL* folderUrl);
    void StartNextRemoteFileItem();
    void RequestCurrentRemoteFileChunk();
    void FinishRemoteFileCopy(bool success);
    void CancelRemoteFileCopy();
    bool PrepareRemoteFileDestinations(NSURL* folderUrl);
    bool CheckWritableFolder(NSURL* folderUrl);
    void ShowFileCopyAlert(NSString* message);
    void UpdateFileCopyWindow(NSString* fileName);
    bool UpdatePasteboardFileItems(int* itemCount);
    bool BuildFileList(char** fileListData, int* fileListLen);
    bool GetPasteboardText(char** utf8Text, int* utf8Len, int* changeCount);
    bool GetPasteboardRtf(char** rtfData, int* rtfLen);
    bool GetPasteboardImage(char** dibData, int* dibLen);
    bool BuildWindowsText(const char* utf8Text, int utf8Len, int formatId, char** outData, int* outDataLen);
    bool SetTextToPasteboard(const void* data, int dataLen, int formatId);
    bool SetRtfToPasteboard(const void* data, int dataLen);
    bool SetImageToPasteboard(const void* data, int dataLen);
};

#endif /* ClipboardManager_hpp */
