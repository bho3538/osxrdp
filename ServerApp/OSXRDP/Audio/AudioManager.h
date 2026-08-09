#ifndef AudioManager_hpp
#define AudioManager_hpp

#include "ipc.h"
#include "xstream.h"
#include <pthread.h>
#include <stdint.h>

// Server side of MS-RDPEA (rdpsnd channel): advertises a single PCM format,
// then streams captured system audio as WAVE2 PDUs to the client
class AudioManager {
public:
    AudioManager();
    ~AudioManager();

    void HandleCommand(xipc_t* client, xstream_t* cmd);
    void HandleCapturedPcm(const void* pcmData, int dataLen);
    void HandleCaptureGiveUp();

private:
    char* _channelBuffer;
    int _channelBufferSize;
    int _channelBufferLen;

    xipc_t* _client;
    int _negotiated;
    int _clientFormatNo;
    unsigned char _blockNo;
    unsigned char _confirmedBlockNo;

    void* _capture;
    void* _outputMuter;
    char* _pcmBuffer;
    int _pcmBufferLen;

    pthread_mutex_t _lock;

    void ResetChannelBuffer();
    bool AssembleChannelData(int channelFlags, int totalLen, const void* data, int dataLen, const void** completeData, int* completeLen);
    void HandleAudioReady(xipc_t* client);
    void HandleAudioPdus(const void* data, int dataLen);
    void HandleClientFormats(const unsigned char* body, int bodySize);
    void HandleWaveConfirm(const unsigned char* body, int bodySize);
    void SendServerAudioFormats(xipc_t* client);
    void SendWave2(xipc_t* client, const void* pcmData, int dataLen, unsigned char blockNo, int formatNo);
    void SendChannelData(xipc_t* client, const void* data, int dataLen);
    bool StartCapture();
    void StopCapture();
    void RestoreLocalOutput();
    static uint32_t CurrentTimeMs();
    static bool IsSilentBlock(const void* pcmData, int dataLen);
};

#endif /* AudioManager_hpp */
