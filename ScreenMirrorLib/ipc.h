#ifndef ipc_h
#define ipc_h

#define MAX_BUFFER 1024 * 16

#include <pthread.h>

#ifdef __cplusplus
extern "C" {
#endif

struct xipc;

typedef int (*xipc_client_onconnected)(struct xipc* ipc, struct xipc* client);
typedef int (*xipc_client_ondisconnected)(struct xipc* ipc, struct xipc* client);
typedef int (*xipc_data_callback)(struct xipc* ipc, struct xipc* client, void* data, int len);

typedef struct xipc_msg {
    int len;
    int num_send;
    char* data;
    struct xipc_msg* next;
} xipc_msg_t;


typedef struct xipc {
    int fd;
    int isServer;
    volatile int closed;
    int unused;
    int wakeup_pipe[2];
    
    char in_buf[MAX_BUFFER];
    int in_len;
    int expected_len;
    
    char* server_name;
    
    pthread_mutex_t lock;
    xipc_msg_t* out_msgs;
    xipc_data_callback on_data;
    xipc_client_onconnected on_client_connected;
    xipc_client_ondisconnected on_client_disconnected;
    void* user_data;
    struct xipc* next;
} xipc_t;

xipc_t* xipc_ctx_create(xipc_data_callback on_data, void* userData);
void xipc_destroy(xipc_t* ipc);

int xipc_create_server(xipc_t* ipc, const char* path, xipc_client_onconnected on_client_connected, xipc_client_ondisconnected on_client_disconnected);
int xipc_connect_server(xipc_t* ipc, const char* path);

int xipc_send_data(xipc_t* ipc, const void* data, int len);
void xipc_loop(xipc_t* ipc);
void xipc_end_loop(xipc_t* ipc);

#ifdef __cplusplus
}
#endif

#endif /* ipc_h */
