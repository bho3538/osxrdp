#ifndef packet_h
#define packet_h

#ifndef OSXRDP_PACKETTYPE
#define OSXRDP_PACKETTYPE

#define OSXRDP_RECORDFORMAT_BGRA32          0
#define OSXRDP_RECORDFORMAT_NV12_PACKED     1
#define OSXRDP_RECORDFORMAT_NV12_ALIGNED    2
#define OSXRDP_RECORDFORMAT_RFX             3

#define OSXRDP_CMDTYPE_SCREEN 1
#define OSXRDP_PACKETTYPE_REQ_SCREEN 1
#define OSXRDP_PACKETTYPE_REP_SCREEN 2
#define OSXRDP_PACKETTYPE_REQ_SCREENOFF 3
#define OSXRDP_PACKETTYPE_REP_SCREENOFF 4
#define OSXRDP_PACKETTYPE_MOUSEEVT      5
#define OSXRDP_PACKETTYPE_KEYBOARDEVT   6
// Dynamic resolution change (MS-RDPEDISP). Payload is identical to REQ_SCREEN
#define OSXRDP_PACKETTYPE_REQ_RESIZE    7
#define OSXRDP_PACKETTYPE_REP_RESIZE    8
// Ask the agent to synthesize a full frame without waiting for new capture
// activity (used by dirty-only formats such as RFX). No payload, no reply
#define OSXRDP_PACKETTYPE_REQ_FULLFRAME 9

#define OSXRDP_CMDTYPE_CLIPBOARD 2
#define OSXRDP_PACKETTYPE_REQ_SETCLIENTCLIP 1
#define OSXRDP_PACKETTYPE_REP_SETCLIENTCLIP 2

#define OSXRDP_CMDTYPE_MSGFROMAGENT 3
#define OSXRDP_PACKETTYPE_TERMINATE 1

#define OSXRDP_CMDTYPE_NEEDPAINT 4

#define OSXRDP_CMDTYPE_AUDIO 5
// module -> agent: rdpsnd channel data received from the RDP client
#define OSXRDP_PACKETTYPE_REQ_SETCLIENTAUDIO 1
// agent -> module: rdpsnd channel data to send to the RDP client
#define OSXRDP_PACKETTYPE_REP_SETCLIENTAUDIO 2
// module -> agent: rdpsnd channel is available for this connection
#define OSXRDP_PACKETTYPE_AUDIO_READY 3


#endif

#ifndef XRDP_KEYBOARD_EVT
#define XRDP_KEYBOARD_EVT

#define XRDP_KEYBOARD_DOWN  15
#define XRDP_KEYBOARD_UP    16
// Client keyboard Synchronize Event (connect/focus regain) — resets modifier state
#define XRDP_KEYBOARD_SYNC  17

#endif


#ifndef XRDP_MOUSE_EVT
#define XRDP_MOUSE_EVT

#define XRDP_MOUSE_MOVE         100
#define XRDP_MOUSE_LBTNUP       101
#define XRDP_MOUSE_LBTNDOWN     102
#define XRDP_MOUSE_RBTNUP       103
#define XRDP_MOUSE_RBTNDOWN     104
#define XRDP_MOUSE_MBTNUP       105
#define XRDP_MOUSE_MBTNDOWN     106
#define XRDP_MOUSE_WHEELUP      107
#define XRDP_MOUSE_WHEELDOWN    109
#define XRDP_MOUSE_BBTNUP       115 // 마우스 뒤로가기키 (측면)
#define XRDP_MOUSE_BBTNDOWN     116
#define XRDP_MOUSE_FBTNUP       117 // 마우스 앞으로가기키 (측면)
#define XRDP_MOUSE_FBTNDOWN     118

#endif


// for sessionmanager
#ifndef OSXRDP_SESSIONMANAGER_PACKETTYPE
#define OSXRDP_SESSIONMANAGER_PACKETTYPE

#define OSXRDP_SESSMAN_REQUEST_SESSION 1
#define OSXRDP_SESSMAN_REPLY_SESSION 2
#define OSXRDP_SESSMAN_REQUEST_RELEASESESSION 3
#define OSXRDP_SESSMAN_REPLY_RELEASESESSION 4 // unused

#endif

#ifndef OSXRDP_CHANNEL_MSG_TYPE
#define OSXRDP_CHANNEL_MSG_TYPE

#define OSXRDP_CHANNEL_CLIPBOARD 0
#define OSXRDP_CHANNEL_AUDIO 1
#define OSXRDP_CHANNEL_INVALID -1

#endif



#endif /* packet_h */
