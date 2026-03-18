

#ifndef auth_h
#define auth_h

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

int osxup_auth_user(const char* username, const char* password, char* canonicalUsername, size_t canonicalUsernameSize);

#if __cplusplus
}
#endif

#endif /* auth_h */
