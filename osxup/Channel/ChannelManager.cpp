#include "../pch.h"
#include "ChannelManager.h"
#include "osxrdp/packet.h"
#include "../osxup.h"

ChannelManager::ChannelManager() :
    _inited(false),
    _clipboardChannelId(-1)
{}

ChannelManager::~ChannelManager()
{}


bool ChannelManager::Initialize(const struct mod* mod) {
    assert(mod != NULL);
    _inited = true;
    
    _clipboardChannelId = mod->server_get_channel_id((struct mod*)mod, CLIPRDR_SVC_CHANNEL_NAME);
    if (_clipboardChannelId < 0) {
        return false;
    }
    
    return true;
}

void ChannelManager::Release() {
    _clipboardChannelId = -1;
    _inited = false;
}


int ChannelManager::IsValidChannelMsg(int channelId, int channelFlags, const char* data, int dataLen, int totalLen) {
    (void)channelFlags;
    (void)data;
    (void)dataLen;
    (void)totalLen;
    
    if (channelId == _clipboardChannelId) {
        return OSXRDP_CHANNEL_CLIPBOARD;
    }
    
    return OSXRDP_CHANNEL_INVALID;
}
