#include "linux_platform_shims.h"

#if defined(__linux__)
#include <errno.h>
#include <stdio.h>
#include <sys/socket.h>

int repo_linux_rename_noreplace(int from_dirfd, const char *from, int to_dirfd, const char *to) {
    return renameat2(from_dirfd, from, to_dirfd, to, RENAME_NOREPLACE);
}

int repo_linux_socket_peer_pid(int fd, pid_t *out_pid) {
    if (out_pid == NULL) {
        errno = EINVAL;
        return -1;
    }
    struct ucred credentials;
    socklen_t length = sizeof(credentials);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &length) != 0) {
        return -1;
    }
    *out_pid = credentials.pid;
    return 0;
}
#endif
