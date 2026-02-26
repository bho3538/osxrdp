#include "RemoteConnectionService.h"

#include "../MirrorAppServer/MirrorAppServer.h"

static MirrorAppServer* g_server = nullptr;

bool StartRemoteConnectionServerService(void) {
    if (g_server != nullptr) {
        return false;
    }

    g_server = new MirrorAppServer();
    g_server->Start();

    return true;
}

void StopRemoteConnectionServerService(void) {
    if (g_server == nullptr) {
        return;
    }

    g_server->Stop();
    delete g_server;
    g_server = nullptr;
}

bool IsRemoteConnectionServerServiceRunning(void) {
    return g_server != nullptr;
}
