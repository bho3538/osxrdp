
#ifndef ChannelManager_h
#define ChannelManager_h

#include "xstream.h"

struct mod;

class ChannelManager {
  
public:
    ChannelManager();
    ~ChannelManager();
    
    bool Initialize(const struct mod* mod);
    void SendClipboardServerInit();
    void SendClipboardChannelData(const void* data, int dataLen, int totalLen, int channelFlags);
    void Release();
    
    int IsValidChannelMsg(int channelId, int channelFlags, const char* data, int dataLen, int totalLen);
    
private:
    bool _inited;
    const struct mod* _mod;
    
    int _clipboardChannelId;
    
    void _SendChannelData(xstream_t* stream);
};

#endif /* ChannelManager_h */
