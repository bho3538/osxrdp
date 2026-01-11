
#include "auth.h"

#include <memory.h>
#include <stdlib.h>
#include <security/pam_appl.h>

int _pam_conv_handler(int num_msg, const struct pam_message **msg, struct pam_response **resp, void *appdata_ptr);
int _verify_mac_user(const char *username, const char *password);

int osxup_auth_user(const char* username, const char* password) {
    if (username == NULL || password == NULL) {
        return 1;
    }
    
    if (!strcmp(username, "root")) {
        return 1;
    }
    
    return _verify_mac_user(username, password);
}

int _pam_conv_handler(int num_msg, const struct pam_message **msg,
                            struct pam_response **resp, void *appdata_ptr) {
    char *password = (char *)appdata_ptr;
    struct pam_response *reply = NULL;

    reply = (struct pam_response *)malloc(sizeof(struct pam_response));
    if (reply == NULL) return PAM_BUF_ERR;

    for (int i = 0; i < num_msg; i++) {
        if (msg[i]->msg_style == PAM_PROMPT_ECHO_OFF ||
            msg[i]->msg_style == PAM_PROMPT_ECHO_ON) {
            reply[i].resp_retcode = 0;
            reply[i].resp = strdup(password);
        }
        else {
            reply[i].resp_retcode = 0;
            reply[i].resp = NULL;
        }
    }

    *resp = reply;
    return PAM_SUCCESS;
}

int _verify_mac_user(const char *username, const char *password) {
    pam_handle_t *pamh = NULL;
    struct pam_conv conv = { _pam_conv_handler, (void *)password };
    int retval;

    retval = pam_start("sshd", username, &conv, &pamh);

    if (retval != PAM_SUCCESS) {
        return 0; // 초기화 실패
    }

    retval = pam_authenticate(pamh, 0);
    if (retval == PAM_SUCCESS) {
        retval = pam_acct_mgmt(pamh, 0);
    }
    
    pam_end(pamh, retval);

    return (retval == PAM_SUCCESS) ? 0 : 1;
}
