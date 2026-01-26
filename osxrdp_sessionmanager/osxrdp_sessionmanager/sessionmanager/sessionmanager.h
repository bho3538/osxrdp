//
//  sessionmanager.h
//  osxrdp_sessionmanager
//
//  Created by byungho on 1/24/26.
//

#ifndef sessionmanager_h
#define sessionmanager_h

#include "osxrdp/sessioninfo.h"

#ifdef __cplusplus
extern "C" {
#endif

int osxrdp_sessionmanager_getsessioninfo(const char* username, session_info_t* sessionInfo);
int osxrdp_sessionmanager_createsession(session_info_t* created_sessionInfo);
void osxrdp_sessionmanager_releasesession(int sessionId);

#ifdef __cplusplus
}
#endif

#endif /* sessionmanager_h */
