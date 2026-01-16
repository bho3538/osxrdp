#include "ipc.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <poll.h>
#include <errno.h>
#include <fcntl.h>

#define MAX_CONNECTION 512

void set_nonBlocking(int fd)
{
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
}

void remove_at_clients_list(xipc_t* server, xipc_t* client)
{
    if (server == NULL || client == NULL)
    {
        return;
    }
    
    if (server->isServer == 0)
    {
        return;
    }
    
    if (client->isServer != 0)
    {
        return;
    }
    
    if (server->next == NULL)
    {
        return;
    }
    
    if (server->next == client)
    {
        server->next = server->next->next;
    }
    else
    {
        xipc_t* tmp = server->next;
        xipc_t* prev = server->next;
        while (tmp != NULL)
        {
            if (tmp == client)
            {
                prev->next = client->next;
                break;
            }
            
            prev = tmp;
            tmp = tmp->next;
        }
    }
    
    client->next = NULL;
}

void prepare_wait_poll(int* currentIndex, struct pollfd* fds, xipc_t** ipcs, xipc_t* ipc);
int accept_new_client(xipc_t* ipc);

int send_data_to_client(xipc_t* client, int* needClose);
int write_data_to_socket(xipc_t* client, xipc_msg_t* msg);

int recv_data_from_client(xipc_t* ipc, xipc_t* client, int* needClose);
int read_header_from_socket(xipc_t* client, int* needClose);
int read_data_from_socket(xipc_t* client, int* needClose);

xipc_t* xipc_ctx_create(xipc_data_callback on_data, void* userData)
{
    xipc_t* ipc = (xipc_t*)malloc(sizeof(xipc_t));
    if (ipc == NULL)
    {
        return NULL;
    }
    
    memset(ipc, 0x00, sizeof(xipc_t));
    
    ipc->on_data = on_data;
    pthread_mutex_init(&ipc->lock, NULL);
    
    if (pipe(ipc->wakeup_pipe) < 0)
    {
        pthread_mutex_destroy(&ipc->lock);
        free(ipc);
        return NULL;
    }
    
    ipc->user_data = userData;
    set_nonBlocking(ipc->wakeup_pipe[0]);
    set_nonBlocking(ipc->wakeup_pipe[1]);
    
    return ipc;
}


void xipc_destroy(xipc_t* ipc)
{
    if (ipc == NULL)
    {
        return;
    }
    
    close(ipc->fd);
    close(ipc->wakeup_pipe[0]);
    close(ipc->wakeup_pipe[1]);

    pthread_mutex_destroy(&ipc->lock);
    
    if (ipc->out_msgs)
    {
        xipc_msg_t* msg = ipc->out_msgs;
        while (msg != NULL)
        {
            xipc_msg_t* tmp = msg;
            msg = msg->next;
            
            free(tmp->data);
            free(tmp);
        }
    }
    
    if (ipc->isServer == 1 && ipc->closed == 1 && ipc->on_client_disconnected)
    {
        xipc_t* client = ipc->next;
        while (client != NULL) {
            ipc->on_client_disconnected(ipc, client);
            
            client = client->next;
        }
    }
    
    if (ipc->next)
    {
        // remove all client info
        xipc_destroy(ipc->next);
    }
    
    free(ipc);
}

int xipc_create_server(xipc_t* ipc, const char* path, xipc_client_onconnected on_client_connected, xipc_client_ondisconnected on_client_disconnected)
{
    if (ipc == NULL || path == NULL)
    {
        return EINVAL;
    }
        
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd <= 0)
    {
        return errno;
    }
    
    unlink(path);
    
    struct sockaddr_un addr = {0,};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - sizeof(char));
    
    if (bind(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0)
    {
        close(fd);
        
        return errno;
    }
    
    if (listen(fd, 10) < 0)
    {
        close(fd);

        return errno;
    }
    
    ipc->fd = fd;
    ipc->isServer = 1;
    ipc->on_client_connected = on_client_connected;
    ipc->on_client_disconnected = on_client_disconnected;

    set_nonBlocking(ipc->fd);
    
    return 0;
}


int xipc_connect_server(xipc_t* ipc, const char* path)
{
    if (ipc == NULL || path == NULL)
    {
        return EINVAL;
    }
    
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd <= 0)
    {
        return errno;
    }
    
    struct sockaddr_un addr = {0,};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - sizeof(char));
    
    if (connect(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0)
    {
        close(fd);
        
        return errno;
    }
    
    ipc->fd = fd;
    ipc->isServer = 0;

    set_nonBlocking(ipc->fd);
    
    return 0;
}

int xipc_send_data(xipc_t* ipc, const void* data, int len)
{
    if (ipc == NULL || data == NULL || len <= 0)
    {
        return -1;
    }
    
    xipc_msg_t* msg = (xipc_msg_t*)malloc(sizeof(xipc_msg_t));
    if (msg == NULL)
    {
        return -1;
    }
    
    msg->num_send = 0;
    msg->next = NULL;
    msg->len = len + sizeof(int);
    msg->data = (char*)malloc(msg->len);
    if (msg->data == NULL)
    {
        free(msg);
        
        return -1;
    }
    
    // header + body
    memcpy(msg->data, &len, sizeof(int));
    memcpy(msg->data + sizeof(int), data, len);
    
    pthread_mutex_lock(&ipc->lock);
    
    if (ipc->out_msgs == NULL)
    {
        ipc->out_msgs = msg;
    }
    else
    {
        xipc_msg_t* tmp = ipc->out_msgs;
        while (tmp->next != NULL)
        {
            tmp = tmp->next;
        }
        
        tmp->next = msg;
    }
    
    pthread_mutex_unlock(&ipc->lock);
    
    // wake up io thread
    write(ipc->wakeup_pipe[1], "W", sizeof(char));
    
    return len;
}

void xipc_loop(xipc_t* ipc)
{
    struct pollfd fds[MAX_CONNECTION * 2];
    xipc_t* ipc_map[MAX_CONNECTION * 2];
    
    int numFds = 0;
    int numFdsHandled = 0;
    
    while (ipc->closed == 0)
    {
        numFds = 0;
        numFdsHandled = 0;
                
        // clients
        pthread_mutex_lock(&ipc->lock);
        
        prepare_wait_poll(&numFds, fds, ipc_map, ipc);
        
        xipc_t* current = ipc->next;
        
        while (current && MAX_CONNECTION * 2)
        {
            prepare_wait_poll(&numFds, fds, ipc_map, current);

            current = current->next;
        }
        
        pthread_mutex_unlock(&ipc->lock);
        
        if (poll(fds, numFds, -1) < 0)
        {
            if (errno == EINTR)
            {
                continue;
            }
            
            break;
        }
        
        while (numFdsHandled < numFds)
        {
            xipc_t* client = ipc_map[numFdsHandled];
            struct pollfd* fdinfo = &fds[numFdsHandled];
            
            if (client == NULL)
            {
                // wakeup pipe
                numFdsHandled++;
                
                client = ipc_map[numFdsHandled];
                fdinfo = &fds[numFdsHandled];
                
                // dummy
                char data[2];
                read(client->wakeup_pipe[0], data, sizeof(char));
                
                fdinfo->revents |= POLLOUT;
            }
            
            // socket
            if (fdinfo->revents & POLLIN)
            {
                if (ipc->isServer != 0 && client->fd == ipc->fd)
                {
                    // accept new client
                    accept_new_client(ipc);
                }
                else
                {
                    int needClose = 0;
                    if (recv_data_from_client(ipc, client, &needClose) != 0)
                    {
                        client->closed = 1;
                    }
                    
                    if (needClose != 0)
                    {
                        client->closed = 1;
                    }
                }
            }
            
            if (client->closed == 0 && fdinfo->revents & POLLOUT)
            {
                int needClose = 0;
                send_data_to_client(client, &needClose);
                
                if (needClose != 0)
                {
                    client->closed = 1;
                }
            }
            
            if (client->closed == 1)
            {
                if (client->isServer == 0 && ipc->on_client_disconnected)
                    ipc->on_client_disconnected(ipc, client);
                
                if (ipc->isServer == 1 && client->isServer == 0)
                {
                    remove_at_clients_list(ipc, client);
                    xipc_destroy(client);
                }
                else
                {
                    goto escapeArea;
                }
                
            }
            
            numFdsHandled++;
        }
    }
    
escapeArea:
    return;
}
void xipc_end_loop(xipc_t* ipc) {
    if (ipc != NULL) {
        ipc->closed = 1;
        write(ipc->wakeup_pipe[1], "W", sizeof(char));
    }
}


int send_data_to_client(xipc_t* client, int* needClose)
{
    if (client == NULL)
    {
        return -1;
    }
    
    // 쌓여있는 데이터들을 전송
    pthread_mutex_lock(&client->lock);
    
    while (client->out_msgs != NULL)
    {
        int error = write_data_to_socket(client, client->out_msgs);
        if (error == 0)
        {
            if (client->out_msgs->num_send >= client->out_msgs->len)
            {
                xipc_msg_t* tmp = client->out_msgs;
                client->out_msgs = client->out_msgs->next;
                
                free(tmp->data);
                free(tmp);
            }
        }
        else
        {
            if (error != EAGAIN)
            {
                *needClose = 1;
            }
            
            break;
        }
    }

    pthread_mutex_unlock(&client->lock);
    return 0;
}

int write_data_to_socket(xipc_t* client, xipc_msg_t* msg)
{
    int numWrite = (int)write(client->fd, msg->data + msg->num_send, msg->len - msg->num_send);
    if (numWrite < 0)
    {
        return errno;
    }
    
    msg->num_send += numWrite;
    return 0;
}

int recv_data_from_client(xipc_t* ipc, xipc_t* client, int* needClose)
{
    if (client == NULL)
    {
        return -1;
    }
    
    if (client->expected_len == 0)
    {
        // read header
        if (read_header_from_socket(client, needClose) != 0)
        {
            return 0;
        }
        
        if (client->in_len >= sizeof(int))
        {
            int expected_len = *(int*)&client->in_buf;
            if (expected_len <= 0 || expected_len >= MAX_BUFFER)
            {
                *needClose = 1;
                return 0;
            }
            
            client->expected_len = expected_len;
            client->in_len = 0;
        }
    }
    
    // read body
    while (client->in_len < client->expected_len)
    {
        if (read_data_from_socket(client, needClose) != 0)
        {
            return 0;
        }
        
        if (*needClose == 1)
        {
            return 0;
        }
    }
    
    // if receive all -> call cb
    if (ipc->on_data)
        ipc->on_data(ipc, client, client->in_buf, client->in_len);
    
    client->in_len = 0;
    client->expected_len = 0;
    
    return 0;
}

int read_header_from_socket(xipc_t* client, int* needClose)
{
    int numRead = (int)read(client->fd, client->in_buf + client->in_len, sizeof(int) - client->in_len);
    if (numRead < 0)
    {
        if (errno != EAGAIN)
        {
            *needClose = 1;
        }
        
        return errno;
    }
    else if (numRead == 0)
    {
        *needClose = 1;
        return 1;
    }
    
    client->in_len += numRead;
    
    return 0;
}

int read_data_from_socket(xipc_t* client, int* needClose)
{
    int numRead = (int)read(client->fd, client->in_buf + client->in_len, client->expected_len - client->in_len);
    if (numRead < 0)
    {
        if (errno != EAGAIN)
        {
            *needClose = 1;
        }
        
        return errno;
    }
    else if (numRead == 0)
    {
        *needClose = 1;
        return 1;
    }
    
    client->in_len += numRead;
    
    return 0;
}

void prepare_wait_poll(int* currentIndex, struct pollfd* fds, xipc_t** ipcs, xipc_t* ipc)
{
    if (*currentIndex >= MAX_CONNECTION * 2)
    {
        return;
    }
    
    // wakeup pipe
    fds[*currentIndex].fd = ipc->wakeup_pipe[0];
    fds[*currentIndex].events = POLLIN;
    fds[*currentIndex].revents = 0;
    ipcs[*currentIndex] = NULL;
    (*currentIndex)++;
    
    // socket
    fds[*currentIndex].fd = ipc->fd;
    fds[*currentIndex].events = POLLIN;
    if (ipc->out_msgs != NULL)
    {
        fds[*currentIndex].events |= POLLOUT;
    }
    fds[*currentIndex].revents = 0;
    ipcs[*currentIndex] = ipc;
    (*currentIndex)++;
}

int accept_new_client(xipc_t* ipc)
{
    int clientFd = accept(ipc->fd, NULL, NULL);
    if (clientFd >= 0)
    {
        // add client
        xipc_t* client = xipc_ctx_create(ipc->on_data, NULL);
        if (client != NULL)
        {
            client->fd = clientFd;
            set_nonBlocking(client->fd);
            
            if (ipc->next == NULL)
            {
                ipc->next = client;
            }
            else
            {
                xipc_t* tmp = ipc->next;
                
                while (tmp->next != NULL)
                {
                    tmp = tmp->next;
                }
                
                tmp->next = client;
            }
            
            if (ipc->on_client_connected)
                ipc->on_client_connected(ipc, client);
        }
    }
    
    return 0;
}
