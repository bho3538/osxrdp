#include "osxup.h"

#ifndef EXPORT_CC
#define EXPORT_CC __attribute__((visibility("default")))
#endif

#include <stdlib.h>
#include <memory.h>

#include "osxrdp/packet.h"
#include "osxrdp/screenrecordshm.h"
#include "paintscreen.h"
#include "command.h"
#include "auth.h"
#include "egfx.h"
#include "utils.h"

static void
lib_init_msgs(struct mod* mod) {
    mod->msgs.paint_msg = xstream_create(4096);
    mod->msgs.mouse_msg = xstream_create(32);
    mod->msgs.keyboard_msg = xstream_create(32);
}

static void
lib_release_msgs(struct mod* mod) {
    xstream_free(mod->msgs.paint_msg);
    xstream_free(mod->msgs.mouse_msg);
    xstream_free(mod->msgs.keyboard_msg);
}

static void*
lib_ipc_thread(void* args) {
    
    struct mod* mod = (struct mod*)args;
    if (mod == NULL)
        return 0;
    
    // blocking
    xipc_loop(mod->cmdIpc);
        
    mod->requestStop = 1;
    
    return NULL;
}

static int
lib_ipc_onmessage(xipc_t* t, xipc_t* client, void* data, int len) {
    if (t == NULL)
        return 0;
    
    struct mod* mod = (struct mod*)t->user_data;
    if (mod == NULL)
        return 0;
    
    xstream_t* stream = xstream_create_for_read(data, len);

    int cmdType = xstream_readInt32(stream);
    switch (cmdType) {
        case OSXRDP_CMDTYPE_SCREEN: {
            int packetType = xstream_readInt32(stream);
            if (packetType == OSXRDP_PACKETTYPE_REP_SCREEN) {
                int re = xstream_readInt32(stream);
                if (re == 1) {
                    char shm_name[512];
                    if (get_object_name(mod->username, "/osxrdpshm", shm_name, 512) == 0) {
                        return 0;
                    }
                    
                    mod->screenShm = xshm_open(shm_name);
                    if (mod->screenShm && mod->screenShm->mem) {
                        osxup_create_surface(mod);

                        // start paint thread
                        mod->runPaint = 1;
                    }
                }
            }
            break;
        }
        case OSXRDP_CMDTYPE_MSGFROMAGENT: {
            int packetType = xstream_readInt32(stream);
            if (packetType == OSXRDP_PACKETTYPE_TERMINATE) {
                mod->requestStop = 1;
            }
            break;
        }
        default:
            break;
    }

    xstream_free(stream);
    return 0;
}



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
    
    lib_init_msgs(mod);
    
    return 0;
}

/******************************************************************************/
/* return error */
static int
lib_mod_connect(struct mod *mod, int fd)
{
    // auth user
    if (osxup_auth_user(mod->username, mod->password)) {
        sleep(1);
        mod->server_msg(mod, "Authentication failed.", 0);
        return 1;
    }
    
    // erase password from memory
    memset(mod->password, 0x01, MAX_PATH);
    memset(mod->password, 0x00, MAX_PATH);
    
    // check rdp client is valid (supported)
    int recordFormat;
    if (mod->client_info.gfx == 1 && mod->client_info.rfx_codec_id == 0) {
        // using H264
        recordFormat = OSXRDP_RECORDFORMAT_NV12;
    }
    else if (mod->client_info.gfx == 1) {
        recordFormat = -1;
    }
    else {
        recordFormat = OSXRDP_RECORDFORMAT_BGRA32;
    }
    
    if (recordFormat == -1) {
        mod->server_msg(mod, "RFX with gfx currently does not supported. Please use another rdp client.", 0);
        return 1;
    }
    
    // create ipc client ctx
    mod->cmdIpc = xipc_ctx_create(lib_ipc_onmessage, mod);
    if (mod->cmdIpc == NULL) {
        return 1;
    }
    
    char server_path[512];
    if (get_object_name(mod->username, "/tmp/osxrdp", server_path, 512) == 0) return 1;
    
    // connect to main agent
    if (xipc_connect_server(mod->cmdIpc, server_path) != 0) {
        mod->server_msg(mod, "OSXRDP agent does not running. Please check main agent is running.", 0);
        return 1;
    }
    
    // run loop
    pthread_create(&mod->ipcThread, NULL, lib_ipc_thread, (void*)mod);
    
    // send record command to agent
    osxup_send_start_cmd(mod->cmdIpc, mod->width, mod->height, recordFormat);

    return 0;
}

/******************************************************************************/
/* return error */
static int
lib_mod_event(struct mod *mod, int msg, long param1, long param2,
              long param3, long param4)
{
    // 화면이 돌아갈때만 처리
    if (mod->runPaint == 0) return 0;
    
    switch (msg) {
        case XRDP_KEYBOARD_UP:
        case XRDP_KEYBOARD_DOWN: {
            osxup_send_keyboard_input(mod->msgs.keyboard_msg, mod->cmdIpc, msg, (int)param3, (int)param4);
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
        case XRDP_MOUSE_FBTNDOWN:{
            short x = (short)param1;
            short y = (short)param2;
            
            osxup_send_input(mod->msgs.mouse_msg, mod->cmdIpc, msg, x, y);
            
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
    if (strcasecmp(name, "username") == 0)
    {
        strncpy(mod->username, value, MAX_PATH - 1);
    }
    else if (strcasecmp(name, "password") == 0)
    {
        strncpy(mod->password, value, MAX_PATH - 1);
    }
    else if (strcasecmp(name, "client_info") == 0)
    {
        memcpy(&(mod->client_info), value, sizeof(mod->client_info));
    }

    return 0;
}

/******************************************************************************/
/* return error */
static int
lib_mod_get_wait_objs(struct mod *mod, void *read_objs, int *rcount,
                      void *write_objs, int *wcount, int *timeout)
{
    long* r = (long*)read_objs;
    r[(*rcount)++] = mod->cmdIpc->fd;
    
    *timeout = 100;
    
    return 0;
}

/******************************************************************************/
/* return error */
static int
lib_mod_check_wait_objs(struct mod *mod)
{
    if (mod->requestStop != 0) return 1;
    if (mod->runPaint == 0) return 0;
    
    osxup_paint(mod);
    
    return 0;
}

/******************************************************************************/
/* return error */
static int
lib_mod_frame_ack(struct mod *amod, int flags, int frame_id)
{
    //osxup_paint_ack(amod->screenShm->mem, frame_id);
    
    return 0;
}

/******************************************************************************/
/* return error */
static int
lib_mod_suppress_output(struct mod *amod, int suppress,
                        int left, int top, int right, int bottom)
{
    if (suppress) amod->runPaint = 0;
    else amod->runPaint = 1;
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
    
    return (void*) mod;
}

/******************************************************************************/
int EXPORT_CC
mod_exit(void* handle)
{
    struct mod *mod = (struct mod *) handle;
    if (mod == 0)
    {
        return 0;
    }
    
    // paint 스레드 정지
    mod->runPaint = 0;
    
    // ipc 정지
    if (mod->cmdIpc != NULL) {
        // 정지 신호를 전송
        osxup_send_stop_cmd(mod->cmdIpc);
        
        sleep(1);
        
        // ipc 정리
        xipc_end_loop(mod->cmdIpc);
        
        // ipc 스레드가 완전히 정지할때까지 대기
        pthread_join(mod->ipcThread, NULL);
        
        xipc_destroy(mod->cmdIpc);
    }
    
    lib_release_msgs(mod);
    
    // 해제
    free(mod);
    
    return 0;
}
