
#include "xshm.h"

#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <sys/socket.h>

xshm_t* xshm_create(const char* name, int size) {
    if (name == NULL || strlen(name) == 0 || size <= 0) {
        return NULL;
    }
    
    // shared memory 생성
    shm_unlink(name);
    int fd = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
    if (fd < 0) {
        return NULL;
    }
    
    // 크기 설정
    if (ftruncate(fd, size) != 0) {
        
        close(fd);
        shm_unlink(name);
        
        return NULL;
    }
    
    // shm 주소 가져오기
    void* addr = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (addr == MAP_FAILED) {
        
        close(fd);
        shm_unlink(name);
        
        return NULL;
    }
    
    xshm_t* shm = (xshm_t*)malloc(sizeof(xshm_t));
    if (shm == NULL) {
        munmap(addr, size);
        close(fd);
        shm_unlink(name);
        
        return NULL;
    }
    
    shm->fd = fd;
    shm->size = size;
    shm->owner = 1;
    shm->mem = addr;
    strcpy(shm->name, name);
    
    return shm;
}

xshm_t* xshm_open(const char* name) {
    if (name == NULL) return NULL;
    
    int fd = shm_open(name, O_RDWR, 0600);
    if (fd < 0) {
        return NULL;
    }
    
    xshm_t* shm = xshm_open_fd(fd);
    if (shm != NULL) {
        strcpy(shm->name, name);
    }
    
    return shm;
}

xshm_t* xshm_open_fd(int fd) {
    if (fd < 0) return NULL;
    
    struct stat st = {0,};
    if (fstat(fd, &st) != 0 || st.st_size == 0) {
        close(fd);
        
        return NULL;
    }
    
    void* addr = mmap(NULL, st.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (addr == MAP_FAILED) {
        close(fd);
        
        return NULL;
    }
    
    xshm_t* shm = (xshm_t*)malloc(sizeof(xshm_t));
    if (shm == NULL) {
        munmap(addr, st.st_size);
        close(fd);
        
        return NULL;
    }
    
    shm->fd = fd;
    shm->size = (int)st.st_size;
    shm->owner = 0;
    shm->mem = addr;
    shm->name[0] = '\0';
    
    return shm;
}

int xshm_send_fds(int sock, const int* fds, const int* tags, int count) {
    if (sock < 0 || fds == NULL || tags == NULL || count <= 0 || count > XSHM_MAX_FDS)
        return 1;
    
    char control[CMSG_SPACE(sizeof(int) * XSHM_MAX_FDS)] = { 0, };
    
    struct iovec iov = { (void*)tags, sizeof(int) * count };
    struct msghdr msg = {0,};
    
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control;
    msg.msg_controllen = (unsigned int)CMSG_SPACE(sizeof(int) * count);
    
    struct cmsghdr* cmsg = CMSG_FIRSTHDR(&msg);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN(sizeof(int) * count);
    memcpy(CMSG_DATA(cmsg), fds, sizeof(int) * count);
    
    return sendmsg(sock, &msg, 0) == iov.iov_len ? 0 : 1;
}

int xshm_recv_fds(int sock, int* fds, int* tags, int maxCount) {
    if (sock < 0 || fds == NULL || tags == NULL || maxCount <= 0 || maxCount > XSHM_MAX_FDS)
        return -1;
    
    char control[CMSG_SPACE(sizeof(int) * XSHM_MAX_FDS)] = {0,};
    
    struct iovec iov = { tags, sizeof(int) * maxCount };
    struct msghdr msg = {0,};
    
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control;
    msg.msg_controllen = sizeof(control);
    
    ssize_t numRead = recvmsg(sock, &msg, 0);
    struct cmsghdr* cmsg = CMSG_FIRSTHDR(&msg);
    
    // 제어 메시지가 잘렸으면 받은 fd 를 신뢰할 수 없으므로 실패 처리
    if (numRead < 0 || (msg.msg_flags & MSG_CTRUNC) || cmsg == NULL ||
        cmsg->cmsg_level != SOL_SOCKET || cmsg->cmsg_type != SCM_RIGHTS) {
        return -1;
    }
    
    int fdCount = (int)((cmsg->cmsg_len - CMSG_LEN(0)) / sizeof(int));
    
    // 개수가 넘치거나 tag 가 fd 마다 하나씩 오지 않았으면 받은 fd 를 닫고 실패 처리
    if (fdCount > maxCount || numRead != (ssize_t)(sizeof(int) * fdCount)) {
        const int* received = (const int*)CMSG_DATA(cmsg);
        for (int i = 0; i < fdCount; i++) {
            close(received[i]);
        }
        return -1;
    }
    
    memcpy(fds, CMSG_DATA(cmsg), sizeof(int) * fdCount);
    
    return fdCount;
}

int xshm_write(xshm_t* shm, const void* data, int len) {
    if (shm == NULL || data == NULL || len <= 0) return 1;
    if (len > shm->size) return 1;
    
    memcpy(shm->mem, data, len);
    
    return 0;
}

int xshm_read(xshm_t* shm, void* buffer, int len) {
    if (shm == NULL || buffer == NULL || len <= 0) return 1;
    if (len > shm->size) return 1;

    memcpy(buffer, shm->mem, len);
    
    return 0;
}

void xshm_close(xshm_t* shm) {
    if (shm == NULL) return;
    
    if (shm->mem) {
        munmap(shm->mem, shm->size);
    }
    
    if (shm->fd >= 0) {
        close(shm->fd);
    }
    
    shm->mem = 0;
    shm->fd = 0;
    shm->size = 0;
}

void xshm_destroy(xshm_t* shm) {
    
    if (shm == NULL) return;
    
    if (shm->owner) {
        shm_unlink(shm->name);
    }
    
    free(shm);
}
