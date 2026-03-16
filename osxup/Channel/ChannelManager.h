
#ifndef ChannelManager_h
#define ChannelManager_h

struct mod;

class ChannelManager {
  
public:
    ChannelManager();
    ~ChannelManager();
    
    bool Initialize(const struct mod* mod);
    void Release();
    
    int IsValidChannelMsg(int channelId, int channelFlags, const char* data, int dataLen, int totalLen);
    
private:
    bool _inited;
    
    int _clipboardChannelId;
    
};

#endif /* ChannelManager_h */
