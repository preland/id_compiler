/* sock_linux.c -- the `sock` backend for Linux.
 *
 * A thin, bounds-checked layer over AF_UNIX SOCK_STREAM: connect (with a
 * retry loop, since the path this exists for is created by another
 * process), send, poll-then-recv, close. A handle is a small integer, the
 * same convention as backends/fs/fs_posix.c and backends/proc/proc_linux.c.
 */
#include "sock.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

typedef struct {
    int used;
    int fd;
} SockSlot;

static SockSlot sock_slots[SOCK_MAX_HANDLES];
static int sock_last_errno = 0;

static int sock_fail(int err) {
    sock_last_errno = err;
    return -1;
}

static SockSlot* sock_get(int handle) {
    if (handle < 0 || handle >= SOCK_MAX_HANDLES) return NULL;
    if (!sock_slots[handle].used) return NULL;
    return &sock_slots[handle];
}

/* Retryable: the path does not exist yet, or exists but nothing is
 * listening on it yet -- both are QEMU not having reached that point in its
 * own boot. Anything else (a path too long, permission denied, ...) is a
 * real error and is not worth retrying. */
static int sock_retryable(int err) {
    return err == ENOENT || err == ECONNREFUSED;
}

int id_sock_connect(const char* path, int timeout_ms) {
    int h;
    struct sockaddr_un addr;
    int elapsed;
    if (!path || !*path) return sock_fail(EINVAL);
    if (strlen(path) >= sizeof addr.sun_path) return sock_fail(ENAMETOOLONG);
    for (h = 0; h < SOCK_MAX_HANDLES; h++) if (!sock_slots[h].used) break;
    if (h == SOCK_MAX_HANDLES) return sock_fail(EMFILE);
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    strcpy(addr.sun_path, path);
    elapsed = 0;
    while (1) {
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) return sock_fail(errno);
        if (connect(fd, (struct sockaddr*)&addr, sizeof addr) == 0) {
            fcntl(fd, F_SETFL, O_NONBLOCK);
            sock_slots[h].used = 1;
            sock_slots[h].fd = fd;
            return h;
        }
        {
            int err = errno;
            close(fd);
            if (!sock_retryable(err)) return sock_fail(err);
            if (elapsed >= timeout_ms) return sock_fail(ETIMEDOUT);
        }
        {
            struct timespec ts;
            ts.tv_sec = 0;
            ts.tv_nsec = 25 * 1000 * 1000;
            nanosleep(&ts, NULL);
        }
        elapsed += 25;
    }
}

int id_sock_send(int handle, IdList* buf, int n) {
    SockSlot* s = sock_get(handle);
    int sent;
    if (!s || !buf) return sock_fail(EBADF);
    if (n < 0) return sock_fail(EINVAL);
    if (n > buf->len) n = buf->len;
    sent = 0;
    while (sent < n) {
        unsigned char chunk[4096];
        int want = (n - sent) < (int)sizeof chunk ? (n - sent) : (int)sizeof chunk;
        int i;
        ssize_t wrote;
        for (i = 0; i < want; i++) chunk[i] = (unsigned char)(buf->data[sent + i] & 0xff);
        wrote = send(s->fd, chunk, (size_t)want, MSG_NOSIGNAL);
        if (wrote < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) continue;
            return sock_fail(errno);
        }
        sent += (int)wrote;
    }
    return sent;
}

int id_sock_recv(int handle, IdList* buf, int n, int timeout_ms) {
    SockSlot* s = sock_get(handle);
    struct pollfd pfd;
    int pr;
    if (!s || !buf) return sock_fail(EBADF);
    if (n < 0) return sock_fail(EINVAL);
    if (n > buf->len) n = buf->len;
    if (n == 0) return 0;
    pfd.fd = s->fd; pfd.events = POLLIN; pfd.revents = 0;
    pr = poll(&pfd, 1, timeout_ms);
    if (pr < 0) return sock_fail(errno);
    if (pr == 0) return 0;
    {
        unsigned char tmp[4096];
        int want = n < (int)sizeof tmp ? n : (int)sizeof tmp;
        ssize_t got = recv(s->fd, tmp, (size_t)want, 0);
        int i;
        if (got < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
            return sock_fail(errno);
        }
        if (got == 0) return 0;
        for (i = 0; i < (int)got; i++) buf->data[i] = (long long)tmp[i];
        return (int)got;
    }
}

int id_sock_close(int handle) {
    SockSlot* s = sock_get(handle);
    if (!s) return sock_fail(EBADF);
    close(s->fd);
    s->used = 0;
    return 0;
}

int id_sock_error(void) {
    return sock_last_errno;
}
