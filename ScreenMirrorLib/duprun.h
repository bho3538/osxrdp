
#ifndef duprun_h
#define duprun_h

#if __cplusplus
extern "C" {
#endif

typedef struct duprun duprun;

duprun* duprun_initialize(const char* lockname);

void duprun_release(duprun* obj);

#if __cplusplus
}
#endif

#endif /* duprun_h */
