#ifndef xstream_h
#define xstream_h

#ifdef __cplusplus
extern "C" {
#endif

typedef struct xstream {
    void* data_start;
    void* data_current;
    
    int size;
    int no_free;
} xstream_t;

xstream_t* xstream_create(int initialSize);
xstream_t* xstream_create_for_read(void* data, int dataSize);
void xstream_free(xstream_t* stream);
void xstream_resetPos(xstream_t* stream);

const void* xstream_get_raw_buffer(xstream_t* stream, int* bufferLen);

int xstream_writeInt8(xstream_t* stream, char data);
int xstream_writeInt16(xstream_t* stream, short data);
int xstream_writeInt32(xstream_t* stream, int data);
int xstream_writeStr(xstream_t* stream, const char* str, int strLen);
int xstream_writeData(xstream_t* stream, void* data, int dataSize);

int xstream_readInt32(xstream_t* stream);
const char* xstream_readStr(xstream_t* stream, int* strLen);

#ifdef __cplusplus
}
#endif


#endif /* xstream_h */
