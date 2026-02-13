

#ifndef auth_h
#define auth_h

#ifdef __cplusplus
extern "C" {
#endif

int osxup_auth_user(const char* username, const char* password);

#if __cplusplus
}
#endif

#endif /* auth_h */
