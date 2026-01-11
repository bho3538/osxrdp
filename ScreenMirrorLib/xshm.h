
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

xshm_t* xshm_create(const char* name, int size);
xshm_t* xshm_open(const char* name);

int xshm_write(xshm_t* shm, const void* data, int len);
int xshm_read(xshm_t* shm, void* buffer, int len);

void xshm_close(xshm_t* shm);
void xshm_destroy(xshm_t* shm);

#ifdef __cplusplus
}
#endif

#endif /* xshm_h */
