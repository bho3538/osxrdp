#ifndef RemoteConnectionService_h
#define RemoteConnectionService_h

bool StartRemoteConnectionServerService(void);
void StopRemoteConnectionServerService(void);
bool IsRemoteConnectionServerServiceRunning(void);
bool HasRemoteClipboardFiles(void);
void StartRemoteClipboardFileCopy(void);

#endif
