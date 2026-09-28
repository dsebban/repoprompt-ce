#ifndef LINUX_PLATFORM_SHIMS_H
#define LINUX_PLATFORM_SHIMS_H

#if defined(__linux__)
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

// renameat2(RENAME_NOREPLACE). Returns 0, or -1 with errno set. Never replaces an existing
// destination and never falls back to a replacing rename.
int repo_linux_rename_noreplace(int from_dirfd, const char *from, int to_dirfd, const char *to);

// Connect-time peer pid of a UNIX-domain socket via SO_PEERCRED. Returns 0, or -1 with errno set.
int repo_linux_socket_peer_pid(int fd, pid_t *out_pid);

#ifdef __cplusplus
}
#endif

#endif /* __linux__ */

#endif /* LINUX_PLATFORM_SHIMS_H */
