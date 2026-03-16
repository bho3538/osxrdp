
#ifndef utils_h
#define utils_h

#ifndef LOWORD
#define LOWORD(l) ((unsigned short)((l) & 0xffff))
#endif

#ifndef HIWORD
#define HIWORD(l) ((unsigned short)(((l) >> 16) & 0xffff))
#endif

#ifdef __cplusplus
extern "C" {
#endif

//int get_object_name_by_username(const char* prefix, char* buffer, int cchMax);

//int get_object_name(const char* username, const char* prefix, char* buffer, int cchMax);
int get_object_name_by_sessionid(const char* prefix, char* buffer, int cchMax, int isLockscreen);

int get_object_name(int sessionid, const char* prefix, char* buffer, int cchMax, int isLockscreen);

int is_root_process(void);

#ifdef __cplusplus
}
#endif

#endif /* utils_h */
