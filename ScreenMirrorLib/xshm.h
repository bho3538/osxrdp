
#ifndef xshm_h
#define xshm_h

#ifdef __cplusplus
extern "C" {
#endif

typedef struct xshm {
    int fd;
    int size;
    int owner;
    int unused;
    void* mem;
    char name[260];
} xshm_t;

// cursor 1 + display record 16
#define XSHM_MAX_FDS 17

xshm_t* xshm_create(const char* name, int size);
xshm_t* xshm_open(const char* name);
xshm_t* xshm_open_fd(int fd);

// unix socket 으로 공유 메모리 fd 를 주고 받기
int xshm_send_fds(int sock, const int* fds, const int* tags, int count);
int xshm_recv_fds(int sock, int* fds, int* tags, int maxCount);

int xshm_write(xshm_t* shm, const void* data, int len);
int xshm_read(xshm_t* shm, void* buffer, int len);

void xshm_close(xshm_t* shm);
void xshm_destroy(xshm_t* shm);

#ifdef __cplusplus
}
#endif

#endif /* xshm_h */
