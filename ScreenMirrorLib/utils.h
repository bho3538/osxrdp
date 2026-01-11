
#ifndef utils_h
#define utils_h

#ifdef __cplusplus
extern "C" {
#endif

int get_object_name_by_username(const char* prefix, char* buffer, int cchMax);

int get_object_name(const char* username, const char* prefix, char* buffer, int cchMax);

#ifdef __cplusplus
}
#endif

#endif /* utils_h */
