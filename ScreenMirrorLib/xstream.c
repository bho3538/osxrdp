#include "xstream.h"

#include <stdlib.h>
#include <memory.h>

int _xstream_sizecheck(xstream_t* stream, int size) {
    if (size <= 0 || stream->size < (stream->data_current - stream->data_start) + size) {
        return 0;
    }
    
    return 1;
}

xstream_t* xstream_create(int initialSize) {
    if (initialSize <= 0) {
        return NULL;
    }
    
    xstream_t* stream = (xstream_t*)malloc(sizeof(xstream_t));
    if (stream == NULL) {
        return NULL;
    }
    
    // init internal buffer
    char* buf = (char*)malloc(initialSize);
    if (buf == NULL) {
        free(stream);
        
        return NULL;
    }
    
    stream->data_start = buf;
    stream->data_current = buf;
    stream->size = initialSize;
    stream->no_free = 0;
    
    return stream;
}

xstream_t* xstream_create_for_read(void* data, int dataSize) {
    if (data == NULL || dataSize <= 0) {
        return NULL;
    }
    
    xstream_t* stream = (xstream_t*)malloc(sizeof(xstream_t));
    if (stream == NULL) {
        return NULL;
    }
    
    stream->data_start = data;
    stream->data_current = data;
    stream->size = dataSize;
    stream->no_free = 1;
    
    return stream;
}

void xstream_resetPos(xstream_t* stream) {
    if (stream == NULL) {
        return;
    }
    
    stream->data_current = stream->data_start;
}

void xstream_free(xstream_t* stream) {
    if (stream == NULL) return;
    
    if (stream->no_free == 0)
        free(stream->data_start);
    
    free(stream);
}

const void* xstream_get_raw_buffer(xstream_t* stream, int* bufferLen) {
    if (stream == NULL || bufferLen == NULL) return NULL;
    
    *bufferLen = (int)(stream->data_current - stream->data_start);
    
    return stream->data_start;
}

int xstream_writeInt8(xstream_t* stream, char data) {
    return xstream_writeData(stream, (void*)&data, sizeof(char));
}

int xstream_writeInt16(xstream_t* stream, short data) {
    return xstream_writeData(stream, (void*)&data, sizeof(short));
}

int xstream_writeInt32(xstream_t* stream, int data) {
    return xstream_writeData(stream, (void*)&data, sizeof(int));
}

int xstream_writeStr(xstream_t* stream, const char* str, int strLen) {
    if (str == NULL || strLen <= 0) return 1;
    if (str[strLen] != '\0') return 1;
    
    if (xstream_writeData(stream, (void*)&strLen, sizeof(int)) != 0) {
        return 1;
    }
    
    if (xstream_writeData(stream, (void*)str, strLen + sizeof(char)) != 0) {
        stream->data_current -= sizeof(int);
        
        return 1;
    }
    
    return 0;
}

int xstream_writeData(xstream_t* stream, void* data, int dataSize) {
    if (_xstream_sizecheck(stream, dataSize) == 0) {
        return 1;
    }
    
    memcpy(stream->data_current, data, dataSize);
    stream->data_current += dataSize;
    
    return 0;
}

int xstream_readInt32(xstream_t* stream) {
    if (_xstream_sizecheck(stream, sizeof(int)) == 0) {
        return 0;
    }
    
    int data = 0;

    memcpy(&data, stream->data_current, sizeof(int));
    
    stream->data_current += sizeof(int);
    
    return data;
}

const char* xstream_readStr(xstream_t* stream, int* strLen) {
    int len = xstream_readInt32(stream);
    if (len <= 0) return NULL;
    
    if (_xstream_sizecheck(stream, len + sizeof(char)) == 0) {
        return NULL;
    }
    
    char* str = (char*)stream->data_current;
    stream->data_current += (len + sizeof(char));
    
    if (strLen != NULL) {
        *strLen = len;
    }
    
    return str;
}
