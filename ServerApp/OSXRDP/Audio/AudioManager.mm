#include "AudioManager.h"

#import <Foundation/Foundation.h>
#import "AudioCapture.h"
#import "AudioOutputMuter.h"
#include "osxrdp/packet.h"
#include "utils.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>

static const int XR_CHANNEL_FLAG_FIRST = 0x00000001;
static const int XR_CHANNEL_FLAG_LAST = 0x00000002;

// MS-RDPEA message types
static const int SNDC_WAVECONFIRM = 0x05;
static const int SNDC_TRAINING = 0x06;
static const int SNDC_FORMATS = 0x07;
static const int SNDC_QUALITYMODE = 0x0C;
static const int SNDC_WAVE2 = 0x0D;

static const int WAVE_FORMAT_PCM_TAG = 0x0001;

// ScreenCaptureKit only supports 8k/16k/24k/48k capture rates
static const int AUDIO_SAMPLE_RATE = 48000;
static const int AUDIO_CHANNEL_COUNT = 2;
static const int AUDIO_BITS_PER_SAMPLE = 16;
static const int AUDIO_BLOCK_ALIGN = AUDIO_CHANNEL_COUNT * (AUDIO_BITS_PER_SAMPLE / 8);
static const int AUDIO_AVG_BYTES_PER_SEC = AUDIO_SAMPLE_RATE * AUDIO_BLOCK_ALIGN;

// 2048 frames per WAVE2 block (~46ms); fits in one IPC message
static const int AUDIO_BLOCK_BYTES = 2048 * AUDIO_BLOCK_ALIGN;
static const int AUDIO_PCM_BUFFER_MAX = AUDIO_BLOCK_BYTES * 8;

// WAVE2 needs client protocol version 8 or later
static const int RDPSND_MIN_CLIENT_VERSION = 8;
static const int RDPSND_SERVER_VERSION = 8;

// Stop sending when the client stops confirming (~3s of audio in flight)
static const int MAX_UNCONFIRMED_BLOCKS = 64;

static const int MAX_AUDIO_CHANNEL_DATA = 1024 * 1024;
static const int MAX_IPC_AUDIO_DATA = 14 * 1024;

// The xrdp core does not fragment channel sends, so stay within the
// static virtual channel chunk limit (CHANNEL_CHUNK_LENGTH) ourselves
static const int RDP_CHANNEL_CHUNK_BYTES = 1600;

static int ReadUInt16LE(const unsigned char* data) {
    return (int)((uint16_t)data[0] | ((uint16_t)data[1] << 8));
}

static int ReadUInt32LE(const unsigned char* data) {
    return (int)((uint32_t)data[0] |
                 ((uint32_t)data[1] << 8) |
                 ((uint32_t)data[2] << 16) |
                 ((uint32_t)data[3] << 24));
}

static void AudioPcmThunk(const void* pcmData, int dataLen, void* userData) {
    AudioManager* manager = (AudioManager*)userData;
    if (manager != NULL) {
        manager->HandleCapturedPcm(pcmData, dataLen);
    }
}

static void AudioGiveUpThunk(void* userData) {
    AudioManager* manager = (AudioManager*)userData;
    if (manager != NULL) {
        manager->HandleCaptureGiveUp();
    }
}

AudioManager::AudioManager()
: _channelBuffer(NULL)
, _channelBufferSize(0)
, _channelBufferLen(0)
, _client(NULL)
, _negotiated(0)
, _clientFormatNo(-1)
, _blockNo(0)
, _confirmedBlockNo(0)
, _capture(NULL)
, _outputMuter(NULL)
, _pcmBuffer(NULL)
, _pcmBufferLen(0) {
    pthread_mutex_init(&_lock, NULL);
    _pcmBuffer = (char*)malloc(AUDIO_PCM_BUFFER_MAX);
}

AudioManager::~AudioManager() {
    StopCapture();

    ResetChannelBuffer();
    if (_pcmBuffer != NULL) {
        free(_pcmBuffer);
        _pcmBuffer = NULL;
    }
    pthread_mutex_destroy(&_lock);
}

void AudioManager::HandleCommand(xipc_t* client, xstream_t* cmd) {
    if (client == NULL || cmd == NULL) {
        return;
    }

    int packetType = xstream_readInt32(cmd);
    if (packetType == OSXRDP_PACKETTYPE_AUDIO_READY) {
        HandleAudioReady(client);
        return;
    }

    if (packetType != OSXRDP_PACKETTYPE_REQ_SETCLIENTAUDIO) {
        return;
    }

    if (xstream_readInt32(cmd) < 0) { // channelId
        return;
    }

    int channelFlags = xstream_readInt32(cmd);
    int totalLen = xstream_readInt32(cmd);
    int dataLen = xstream_readInt32(cmd);
    const void* data = xstream_readData(cmd, dataLen);

    if (totalLen <= 0 ||
        totalLen > MAX_AUDIO_CHANNEL_DATA ||
        dataLen < 0 ||
        dataLen > totalLen ||
        data == NULL) {
        return;
    }

    pthread_mutex_lock(&_lock);
    _client = client;
    pthread_mutex_unlock(&_lock);

    const void* completeData = NULL;
    int completeLen = 0;
    if (AssembleChannelData(channelFlags, totalLen, data, dataLen, &completeData, &completeLen) == false) {
        return;
    }

    HandleAudioPdus(completeData, completeLen);

    if (completeData == _channelBuffer) {
        ResetChannelBuffer();
    }
}

void AudioManager::HandleAudioReady(xipc_t* client) {
    if (is_root_process() == 1) {
        // No user audio exists in the pre-login session
        return;
    }

    if (@available(macOS 13.0, *)) {
        pthread_mutex_lock(&_lock);
        _client = client;
        pthread_mutex_unlock(&_lock);

        NSLog(@"[AudioManager] Audio channel ready, sending server formats");
        SendServerAudioFormats(client);
    } else {
        NSLog(@"[AudioManager] System audio capture requires macOS 13 or later");
    }
}

void AudioManager::ResetChannelBuffer() {
    if (_channelBuffer != NULL) {
        free(_channelBuffer);
        _channelBuffer = NULL;
    }
    _channelBufferSize = 0;
    _channelBufferLen = 0;
}

bool AudioManager::AssembleChannelData(int channelFlags, int totalLen, const void* data, int dataLen, const void** completeData, int* completeLen) {
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

        _channelBuffer = (char*)malloc(totalLen);
        if (_channelBuffer == NULL) {
            return false;
        }
        _channelBufferSize = totalLen;
        _channelBufferLen = 0;
    }

    if (_channelBuffer == NULL || _channelBufferLen + dataLen > _channelBufferSize) {
        ResetChannelBuffer();
        return false;
    }

    memcpy(_channelBuffer + _channelBufferLen, data, dataLen);
    _channelBufferLen += dataLen;

    if ((channelFlags & XR_CHANNEL_FLAG_LAST) == 0) {
        return false;
    }

    *completeData = _channelBuffer;
    *completeLen = _channelBufferLen;
    return true;
}

void AudioManager::HandleAudioPdus(const void* data, int dataLen) {
    const unsigned char* bytes = (const unsigned char*)data;
    int offset = 0;

    while (offset + 4 <= dataLen) {
        int msgType = bytes[offset];
        int bodySize = ReadUInt16LE(bytes + offset + 2);

        if (bodySize < 0 || offset + 4 + bodySize > dataLen) {
            break;
        }

        const unsigned char* body = bytes + offset + 4;
        switch (msgType) {
            case SNDC_FORMATS:
                HandleClientFormats(body, bodySize);
                break;
            case SNDC_WAVECONFIRM:
                HandleWaveConfirm(body, bodySize);
                break;
            case SNDC_QUALITYMODE:
            case SNDC_TRAINING:
                break;
            default:
                break;
        }

        offset += 4 + bodySize;
    }
}

void AudioManager::HandleClientFormats(const unsigned char* body, int bodySize) {
    if (bodySize < 20) {
        return;
    }

    int numberOfFormats = ReadUInt16LE(body + 14);
    int clientVersion = ReadUInt16LE(body + 17);

    int formatNo = -1;
    int offset = 20;
    for (int i = 0; i < numberOfFormats; i++) {
        if (offset + 18 > bodySize) {
            break;
        }

        int formatTag = ReadUInt16LE(body + offset);
        int channels = ReadUInt16LE(body + offset + 2);
        int samplesPerSec = ReadUInt32LE(body + offset + 4);
        int bitsPerSample = ReadUInt16LE(body + offset + 14);
        int cbSize = ReadUInt16LE(body + offset + 16);

        if (formatNo < 0 &&
            formatTag == WAVE_FORMAT_PCM_TAG &&
            channels == AUDIO_CHANNEL_COUNT &&
            samplesPerSec == AUDIO_SAMPLE_RATE &&
            bitsPerSample == AUDIO_BITS_PER_SAMPLE) {
            formatNo = i;
        }

        offset += 18 + cbSize;
    }

    NSLog(@"[AudioManager] Client formats: count=%d version=%d matchedFormatNo=%d",
          numberOfFormats, clientVersion, formatNo);

    if (formatNo < 0 || clientVersion < RDPSND_MIN_CLIENT_VERSION) {
        NSLog(@"[AudioManager] Audio disabled: no matching PCM format or client version too old");
        return;
    }

    bool startCapture = false;
    pthread_mutex_lock(&_lock);
    if (_negotiated == 0) {
        _negotiated = 1;
        _clientFormatNo = formatNo;
        startCapture = true;
    }
    pthread_mutex_unlock(&_lock);

    if (startCapture) {
        StartCapture();
    }
}

void AudioManager::HandleWaveConfirm(const unsigned char* body, int bodySize) {
    if (bodySize < 3) {
        return;
    }

    unsigned char confirmedBlockNo = body[2];
    pthread_mutex_lock(&_lock);
    // Only accept confirms inside the (confirmed, sent] window; anything
    // else would wedge the unconfirmed-block gate permanently
    unsigned char forward = (unsigned char)(confirmedBlockNo - _confirmedBlockNo);
    unsigned char window = (unsigned char)(_blockNo - _confirmedBlockNo);
    if (forward != 0 && forward <= window) {
        _confirmedBlockNo = confirmedBlockNo;
    }
    pthread_mutex_unlock(&_lock);
}

void AudioManager::SendServerAudioFormats(xipc_t* client) {
    xstream_t* stream = xstream_create(64);
    if (stream == NULL) {
        return;
    }

    // Sound PDU header
    xstream_writeInt8(stream, SNDC_FORMATS);
    xstream_writeInt8(stream, 0);
    xstream_writeInt16(stream, 20 + 18); // body + one AUDIO_FORMAT

    xstream_writeInt32(stream, 0);            // dwFlags
    xstream_writeInt32(stream, 0xFFFFFFFF);   // dwVolume (full, both channels)
    xstream_writeInt32(stream, 0);            // dwPitch
    xstream_writeInt16(stream, 0);            // wDGramPort
    xstream_writeInt16(stream, 1);            // wNumberOfFormats
    xstream_writeInt8(stream, 0);             // cLastBlockConfirmed
    xstream_writeInt16(stream, RDPSND_SERVER_VERSION);
    xstream_writeInt8(stream, 0);             // bPad

    // AUDIO_FORMAT: PCM 48kHz / 16bit / stereo
    xstream_writeInt16(stream, WAVE_FORMAT_PCM_TAG);
    xstream_writeInt16(stream, AUDIO_CHANNEL_COUNT);
    xstream_writeInt32(stream, AUDIO_SAMPLE_RATE);
    xstream_writeInt32(stream, AUDIO_AVG_BYTES_PER_SEC);
    xstream_writeInt16(stream, AUDIO_BLOCK_ALIGN);
    xstream_writeInt16(stream, AUDIO_BITS_PER_SAMPLE);
    xstream_writeInt16(stream, 0);            // cbSize

    int bufferLen = 0;
    const void* buffer = xstream_get_raw_buffer(stream, &bufferLen);
    SendChannelData(client, buffer, bufferLen);

    xstream_free(stream);
}

void AudioManager::SendWave2(xipc_t* client, const void* pcmData, int dataLen, unsigned char blockNo, int formatNo) {
    xstream_t* stream = xstream_create(dataLen + 16);
    if (stream == NULL) {
        return;
    }

    uint32_t timeMs = CurrentTimeMs();

    xstream_writeInt8(stream, SNDC_WAVE2);
    xstream_writeInt8(stream, 0);
    xstream_writeInt16(stream, 12 + dataLen);

    xstream_writeInt16(stream, (int)(timeMs & 0xFFFF)); // wTimeStamp
    xstream_writeInt16(stream, formatNo);               // wFormatNo
    xstream_writeInt8(stream, blockNo);                 // cBlockNo
    xstream_writeInt8(stream, 0);
    xstream_writeInt8(stream, 0);
    xstream_writeInt8(stream, 0);
    xstream_writeInt32(stream, (int)timeMs);            // dwAudioTimeStamp
    xstream_writeData(stream, (void*)pcmData, dataLen);

    int bufferLen = 0;
    const void* buffer = xstream_get_raw_buffer(stream, &bufferLen);
    SendChannelData(client, buffer, bufferLen);

    xstream_free(stream);
}

void AudioManager::SendChannelData(xipc_t* client, const void* data, int dataLen) {
    if (client == NULL || data == NULL || dataLen <= 0 || dataLen > MAX_IPC_AUDIO_DATA) {
        return;
    }

    const char* bytes = (const char*)data;
    int offset = 0;

    while (offset < dataLen) {
        int chunkLen = dataLen - offset;
        if (chunkLen > RDP_CHANNEL_CHUNK_BYTES) {
            chunkLen = RDP_CHANNEL_CHUNK_BYTES;
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

        xstream_writeInt32(stream, OSXRDP_CMDTYPE_AUDIO);
        xstream_writeInt32(stream, OSXRDP_PACKETTYPE_REP_SETCLIENTAUDIO);
        xstream_writeInt32(stream, channelFlags);
        xstream_writeInt32(stream, dataLen);
        xstream_writeInt32(stream, chunkLen);
        xstream_writeData(stream, (void*)(bytes + offset), chunkLen);

        int bufferLen = 0;
        const void* buffer = xstream_get_raw_buffer(stream, &bufferLen);
        xipc_send_data(client, buffer, bufferLen);

        xstream_free(stream);
        offset += chunkLen;
    }
}

bool AudioManager::StartCapture() {
    if (_capture != NULL) {
        return true;
    }

    AudioCapture* capture = [[AudioCapture alloc] initWithSampleRate:AUDIO_SAMPLE_RATE
                                                        channelCount:AUDIO_CHANNEL_COUNT
                                                            callback:AudioPcmThunk
                                                      giveUpCallback:AudioGiveUpThunk
                                                    callbackUserData:this];
    if ([capture start] == NO) {
        NSLog(@"[AudioManager] System audio capture unavailable on this system");
        return false;
    }

    _capture = (__bridge_retained void*)capture;

    // The remote side hears the audio, so keep the local speakers silent
    AudioOutputMuter* muter = [[AudioOutputMuter alloc] init];
    [muter mute];
    pthread_mutex_lock(&_lock);
    _outputMuter = (__bridge_retained void*)muter;
    pthread_mutex_unlock(&_lock);

    NSLog(@"[AudioManager] System audio capture starting, local output muted");
    return true;
}

void AudioManager::StopCapture() {
    if (_capture != NULL) {
        AudioCapture* capture = (__bridge_transfer AudioCapture*)_capture;
        _capture = NULL;
        [capture stop];
    }

    RestoreLocalOutput();
}

void AudioManager::RestoreLocalOutput() {
    pthread_mutex_lock(&_lock);
    void* muterRef = _outputMuter;
    _outputMuter = NULL;
    pthread_mutex_unlock(&_lock);

    if (muterRef != NULL) {
        AudioOutputMuter* muter = (__bridge_transfer AudioOutputMuter*)muterRef;
        [muter restore];
    }
}

void AudioManager::HandleCaptureGiveUp() {
    NSLog(@"[AudioManager] Capture gave up; restoring local audio output");
    RestoreLocalOutput();
}

void AudioManager::HandleCapturedPcm(const void* pcmData, int dataLen) {
    if (pcmData == NULL || dataLen <= 0 || _pcmBuffer == NULL) {
        return;
    }

    char block[AUDIO_BLOCK_BYTES];

    pthread_mutex_lock(&_lock);
    if (_pcmBufferLen + dataLen > AUDIO_PCM_BUFFER_MAX) {
        // The client is not draining; drop the backlog instead of growing it
        _pcmBufferLen = 0;
    }
    int copyLen = dataLen > AUDIO_PCM_BUFFER_MAX ? AUDIO_PCM_BUFFER_MAX : dataLen;
    memcpy(_pcmBuffer + _pcmBufferLen, pcmData, copyLen);
    _pcmBufferLen += copyLen;
    pthread_mutex_unlock(&_lock);

    while (1) {
        xipc_t* client = NULL;
        bool sendBlock = false;
        unsigned char blockNo = 0;
        int formatNo = -1;

        pthread_mutex_lock(&_lock);
        if (_pcmBufferLen < AUDIO_BLOCK_BYTES) {
            pthread_mutex_unlock(&_lock);
            break;
        }

        memcpy(block, _pcmBuffer, AUDIO_BLOCK_BYTES);
        _pcmBufferLen -= AUDIO_BLOCK_BYTES;
        memmove(_pcmBuffer, _pcmBuffer + AUDIO_BLOCK_BYTES, _pcmBufferLen);

        client = _client;
        int outstanding = (unsigned char)(_blockNo - _confirmedBlockNo);
        if (_negotiated != 0 && client != NULL && outstanding < MAX_UNCONFIRMED_BLOCKS &&
            IsSilentBlock(block, AUDIO_BLOCK_BYTES) == false) {
            _blockNo = (unsigned char)(_blockNo + 1);
            blockNo = _blockNo;
            formatNo = _clientFormatNo;
            sendBlock = true;
        }
        pthread_mutex_unlock(&_lock);

        if (sendBlock) {
            SendWave2(client, block, AUDIO_BLOCK_BYTES, blockNo, formatNo);
        }
    }
}

uint32_t AudioManager::CurrentTimeMs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)((uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000);
}

bool AudioManager::IsSilentBlock(const void* pcmData, int dataLen) {
    const int16_t* samples = (const int16_t*)pcmData;
    int count = dataLen / (int)sizeof(int16_t);

    for (int i = 0; i < count; i++) {
        if (samples[i] != 0) {
            return false;
        }
    }
    return true;
}
