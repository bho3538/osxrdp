#include "pch.h"
#include "osxup.h"
#include "auth.h"
#include "osxrdp/packet.h"
#include "Connection/MultipleConnectionManager.h"

#include <unistd.h>
#include <stdint.h>

#ifndef EXPORT_CC
#define EXPORT_CC __attribute__((visibility("default")))
#endif

// 가상 모니터 등과 같은 이유로 지금은 다중 사용자의 동시 접속을 지원하지 않음
MultipleConnectionManager _multipleConn;

int g_FailedAuth = 0;

/******************************************************************************/
/* return error */
static int
lib_mod_start(struct mod *mod, int w, int h, int bpp)
{
    mod->width = w;
    mod->height = h;
    mod->bpp = bpp;
    
    // 홀수 해상도일 경우 nv12 인코딩에서 문제가 발생...
    mod->width &= ~0x1;
    mod->height &= ~0x1;
    
    return 0;
}

/******************************************************************************/
/* return error */
static int
lib_mod_connect(struct mod *mod, int fd)
{
    char canonicalUsername[MAX_PATH] = {0,};

    // 사용자 인증 (macOS 계정)
    if (strlen(mod->username) == 0 || strlen(mod->password) == 0) {
        mod->server_msg(mod, "Authentication failed.", 0);
        return 1;
    }
    
    if (osxup_auth_user(mod->username, mod->password, canonicalUsername, sizeof(canonicalUsername)) != 0) {
        g_FailedAuth++;
        
        if (g_FailedAuth > 5) {
            sleep(10);
            g_FailedAuth = 0;
        }
        else {
            sleep(1);
        }
        
        mod->server_msg(mod, "Authentication failed.", 0);
        
        return 1;
    }
    g_FailedAuth = 0;
    
    // 아직 다중접속을 지원하지 않음
    _multipleConn.AddConnection(mod);

    strncpy(mod->username, canonicalUsername, MAX_PATH - 1);
    mod->username[MAX_PATH - 1] = '\0';
    
    // erase password
    memset(mod->password, 0x01, MAX_PATH);
    memset(mod->password, 0x00, MAX_PATH);
    
    // check multi mon compatiable
    if (mod->client_info.display_sizes.monitorCount > 1 && PaintManager::CheckRecordFormat(mod) != OSXRDP_RECORDFORMAT_NV12_PACKED) {
        mod->server_msg(mod, "Multiple monitor only support H.264 format", 0);
        mod->server_msg(mod, "Please disable multiple monitor options on client.", 0);

        return 1;
    }
    
    // connection manager 를 초기화 (sessionmanager와 연결)
    if (mod->connectionManager->Initialize() != 0) {
        mod->server_msg(mod, "Could not connect to sessionmanager.", 0);

        return 1;
    }
    
    if (mod->connectionManager->Connect(mod) == false) {
        mod->server_msg(mod, "No compatible graphics codec negotiated.", 0);
        mod->server_msg(mod, "Please use another client.", 0);

        return 1;
    }

    return 0;
}

/******************************************************************************/
/* return error */
static int
lib_mod_event(struct mod *mod, int msg, long param1, long param2,
              long param3, long param4)
{
    assert(mod->connectionManager != NULL);

    switch (msg) {
        case WM_CHANNEL_DATA: {
            mod->connectionManager->HandleChannelMsg(param1, param2, param3, param4);
            
            break;
        }
        case XRDP_KEYBOARD_UP:
        case XRDP_KEYBOARD_DOWN: {
            if (mod->connectionManager->CanAcceptInput() == false) return 0;
            mod->connectionManager->SendKeyboardInput(msg, (int)param3, (int)param4);
            
            break;
        }
        case WM_KEYBRD_SYNC: {
            mod->connectionManager->SendInputSync((int)param1);
            break;
        }
            
        case XRDP_MOUSE_MOVE:
        case XRDP_MOUSE_LBTNUP:
        case XRDP_MOUSE_LBTNDOWN:
        case XRDP_MOUSE_RBTNUP:
        case XRDP_MOUSE_RBTNDOWN:
        case XRDP_MOUSE_MBTNUP:
        case XRDP_MOUSE_MBTNDOWN:
        case XRDP_MOUSE_WHEELUP:
        case XRDP_MOUSE_WHEELDOWN:
        case XRDP_MOUSE_BBTNUP:
        case XRDP_MOUSE_BBTNDOWN:
        case XRDP_MOUSE_FBTNUP:
        case XRDP_MOUSE_FBTNDOWN:
        case WM_TOUCH_VSCROLL:
        case WM_TOUCH_HSCROLL: {
            if (mod->connectionManager->CanAcceptInput() == false) return 0;
            short x = (short)param1;
            short y = (short)param2;
            int delta = (msg == WM_TOUCH_VSCROLL || msg == WM_TOUCH_HSCROLL) ? (int)param3 : 0;

            mod->connectionManager->SendMouseInput(msg, x, y, delta);
            
            break;
        }
        default:
            return 1;
    }
    
    
    return 0;
}

/******************************************************************************/
/* return error */
static int
lib_mod_signal(struct mod *mod)
{
    // no-op
    return 0;
}

/******************************************************************************/
/* return error */
static int
lib_mod_end(struct mod *mod)
{
    return 0;
}

/******************************************************************************/
/* return error */
static int
lib_mod_set_param(struct mod *mod, const char *name, const char *value)
{
    if (strcasecmp(name, "username") == 0) {
        strncpy(mod->username, value, MAX_PATH - 1);
        mod->username[MAX_PATH - 1] = '\0';
    }
    else if (strcasecmp(name, "password") == 0) {
        strncpy(mod->password, value, MAX_PATH - 1);
        mod->password[MAX_PATH - 1] = '\0';
    }
    else if (strcasecmp(name, "client_info") == 0) {
        memcpy(&(mod->client_info), value, sizeof(mod->client_info));
    }
    else if (strcasecmp(name, "virtualmon") == 0) {
        if (strcasecmp(value, "yes") == 0) {
            mod->usevirtualmon = 1;
        }
        else {
            mod->usevirtualmon = 0;
        }
    }
    /*
    else if (strcasecmp(name, "usevtoolbox") == 0) {
        if (strcasecmp(value, "yes") == 0) {
            mod->usevtoolbox = 1;
        }
        else {
            mod->usevtoolbox = 0;
        }
    }
    */
    mod->usevtoolbox = 0;

    return 0;
}

/******************************************************************************/
/* return error */
static int
lib_mod_get_wait_objs(struct mod *mod, void *read_objs, int *rcount,
                      void *write_objs, int *wcount, int *timeout)
{
    mod->connectionManager->GetWaitObjects(read_objs, rcount);

    *timeout = 100;
    
    return 0;
}

/******************************************************************************/
/* return error */
static int
lib_mod_check_wait_objs(struct mod *mod)
{
    // main loop
    mod->connectionManager->KeepAlive();
    
    // 연결을 종료해야하는지 확인
    if (mod->connectionManager->NeedTerminate() == true) {
        return 1;
    }
    
    // 화면을 그릴 수 있는 상태인지 확인
    if (mod->connectionManager->CanPaint() == false) {
        return 0;
    }
    
    // 화면을 그리기
    mod->connectionManager->Paint();

    return 0;
}

/******************************************************************************/
/* return error */
static int
lib_mod_frame_ack(struct mod *mod, int flags, int frame_id)
{
    (void)flags;
    mod->connectionManager->PaintEnd(frame_id);
    
    return 0;
}

/******************************************************************************/
/* return error */
static int
lib_mod_suppress_output(struct mod *mod, int suppress,
                        int left, int top, int right, int bottom)
{
    // suppress
    mod->connectionManager->SetSuppress(suppress == 0 ? false : true);
    
    return 0;
}

/******************************************************************************/
/* return error */
static int
lib_send_server_version_message(struct mod *mod)
{
    return 0;
}

/******************************************************************************/
/* return error */
static int
lib_send_server_monitor_resize(struct mod *mod, int width, int height,
                               int num_monitors,
                               const struct monitor_info *monitors,
                               int *in_progress)
{
    return 0;
}

/******************************************************************************/
/* return error */
static int
lib_send_server_monitor_full_invalidate(struct mod *mod, int width, int height)
{
    return 0;
}

/******************************************************************************/

extern "C" {

void* EXPORT_CC
mod_init(void)
{
    struct mod* mod;
    
    mod = (struct mod*)malloc(sizeof(struct mod));
    memset(mod, 0x00, sizeof(struct mod));
    
    mod->size = sizeof(struct mod);
    mod->version = CURRENT_MOD_VER;
    mod->mod_connect = lib_mod_connect;
    mod->mod_start = lib_mod_start;
    mod->mod_event = lib_mod_event;
    mod->mod_signal = lib_mod_signal;
    mod->mod_end = lib_mod_end;
    mod->mod_set_param = lib_mod_set_param;
    mod->mod_get_wait_objs = lib_mod_get_wait_objs;
    mod->mod_check_wait_objs = lib_mod_check_wait_objs;
    mod->mod_frame_ack = lib_mod_frame_ack;
    mod->mod_suppress_output = lib_mod_suppress_output;
    mod->mod_server_monitor_resize = lib_send_server_monitor_resize;
    mod->mod_server_monitor_full_invalidate = lib_send_server_monitor_full_invalidate;
    mod->mod_server_version_message = lib_send_server_version_message;
    
    
    mod->connectionManager = new ConnectionManager();
    if (mod->connectionManager == NULL) {
        free(mod);
        
        return NULL;
    }
    
    return (void*)mod;
}

/******************************************************************************/
int EXPORT_CC
mod_exit(void* handle)
{
    struct mod* mod = (struct mod*)handle;
    if (mod == 0) {
        return 0;
    }
    
    _multipleConn.RemoveConnection();
    
    if (mod->connectionManager != NULL) {
        mod->connectionManager->Release();
        
        delete mod->connectionManager;
    }
    
    free(mod);
    
    return 0;
}

}
