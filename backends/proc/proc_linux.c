/* proc_linux.c -- the `proc` backend for Linux.
 *
 * fork/exec/pipe/waitpid/kill behind the six entry points in proc.h. A
 * handle is a small integer, exactly like backends/fs/fs_posix.c's FILE*
 * table, and every failure path goes through proc_fail so id_proc_error is
 * never stale in one place and fresh in another.
 */
#include "proc.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

typedef struct {
    int used;
    pid_t pid;
    int fd;         /* the child's stdout, read end, non-blocking */
    int reaped;
    int exit_code;
} ProcSlot;

static ProcSlot proc_slots[PROC_MAX_HANDLES];
static int proc_last_errno = 0;

static int proc_fail(int err) {
    proc_last_errno = err;
    return -1;
}

static ProcSlot* proc_get(int handle) {
    if (handle < 0 || handle >= PROC_MAX_HANDLES) return NULL;
    if (!proc_slots[handle].used) return NULL;
    return &proc_slots[handle];
}

/* argv_lines split on '\n' into a NULL-terminated argv for execvp. Every
 * string is strdup'd so the child's exec has its own copy; the array and its
 * strings are freed by the caller once the fork is done with them. */
static char** proc_split_argv(const char* lines, int* out_argc) {
    int cap = 8, argc = 0;
    char** argv = (char**)malloc((size_t)cap * sizeof *argv);
    const char* p = lines;
    if (!argv) return NULL;
    while (*p) {
        const char* start = p;
        char* piece;
        size_t len;
        while (*p && *p != '\n') p++;
        len = (size_t)(p - start);
        piece = (char*)malloc(len + 1);
        if (!piece) { argv[argc] = NULL; return argv; }
        memcpy(piece, start, len);
        piece[len] = '\0';
        if (argc + 1 >= cap) {
            int grown = cap * 2;
            char** bigger = (char**)realloc(argv, (size_t)grown * sizeof *argv);
            if (!bigger) { free(piece); argv[argc] = NULL; return argv; }
            argv = bigger; cap = grown;
        }
        argv[argc++] = piece;
        if (*p == '\n') p++;
    }
    argv[argc] = NULL;
    *out_argc = argc;
    return argv;
}

static void proc_free_argv(char** argv) {
    int i;
    if (!argv) return;
    for (i = 0; argv[i]; i++) free(argv[i]);
    free(argv);
}

int id_proc_spawn(const char* argv_lines) {
    int h, argc = 0, outpipe[2];
    char** argv;
    pid_t pid;
    if (!argv_lines || !*argv_lines) return proc_fail(EINVAL);
    for (h = 0; h < PROC_MAX_HANDLES; h++) if (!proc_slots[h].used) break;
    if (h == PROC_MAX_HANDLES) return proc_fail(EMFILE);
    argv = proc_split_argv(argv_lines, &argc);
    if (!argv || argc == 0) { proc_free_argv(argv); return proc_fail(EINVAL); }
    if (pipe(outpipe) != 0) { proc_free_argv(argv); return proc_fail(errno); }
    pid = fork();
    if (pid < 0) {
        int err = errno;
        close(outpipe[0]); close(outpipe[1]); proc_free_argv(argv);
        return proc_fail(err);
    }
    if (pid == 0) {
        int devnull = open("/dev/null", O_RDWR);
        if (devnull >= 0) {
            dup2(devnull, 0);
            dup2(devnull, 2);
        }
        dup2(outpipe[1], 1);
        close(outpipe[0]);
        close(outpipe[1]);
        if (devnull >= 0) close(devnull);
        execvp(argv[0], argv);
        _exit(127);
    }
    close(outpipe[1]);
    fcntl(outpipe[0], F_SETFL, O_NONBLOCK);
    proc_free_argv(argv);
    proc_slots[h].used = 1;
    proc_slots[h].pid = pid;
    proc_slots[h].fd = outpipe[0];
    proc_slots[h].reaped = 0;
    proc_slots[h].exit_code = 0;
    return h;
}

int id_proc_read(int handle, IdList* buf, int n, int timeout_ms) {
    ProcSlot* s = proc_get(handle);
    if (!s || !buf) return proc_fail(EBADF);
    if (n < 0) return proc_fail(EINVAL);
    if (n > buf->len) n = buf->len;
    if (n == 0) return 0;
    {
        struct pollfd pfd;
        int pr;
        pfd.fd = s->fd; pfd.events = POLLIN; pfd.revents = 0;
        pr = poll(&pfd, 1, timeout_ms);
        if (pr < 0) return proc_fail(errno);
        if (pr == 0) return 0;
        {
            unsigned char tmp[4096];
            int want = n < (int)sizeof tmp ? n : (int)sizeof tmp;
            ssize_t got = read(s->fd, tmp, (size_t)want);
            int i;
            if (got < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
                return proc_fail(errno);
            }
            if (got == 0) return 0;
            for (i = 0; i < (int)got; i++) buf->data[i] = (long long)tmp[i];
            return (int)got;
        }
    }
}

int id_proc_wait(int handle, int timeout_ms) {
    ProcSlot* s = proc_get(handle);
    int elapsed;
    if (!s) return proc_fail(EBADF);
    if (s->reaped) return s->exit_code;
    if (timeout_ms < 0) return proc_fail(EINVAL);
    elapsed = 0;
    while (1) {
        int status;
        pid_t r = waitpid(s->pid, &status, WNOHANG);
        if (r == s->pid) {
            int code;
            if (WIFEXITED(status)) code = WEXITSTATUS(status);
            else if (WIFSIGNALED(status)) code = 128 + WTERMSIG(status);
            else code = -1;
            s->reaped = 1;
            s->exit_code = code;
            return code;
        }
        if (r < 0) return proc_fail(errno);
        if (elapsed >= timeout_ms) return proc_fail(ETIMEDOUT);
        {
            struct timespec ts;
            ts.tv_sec = 0;
            ts.tv_nsec = 5 * 1000 * 1000;
            nanosleep(&ts, NULL);
        }
        elapsed += 5;
    }
}

int id_proc_kill(int handle) {
    ProcSlot* s = proc_get(handle);
    if (!s) return proc_fail(EBADF);
    if (kill(s->pid, SIGKILL) != 0) return proc_fail(errno);
    return 0;
}

int id_proc_close(int handle) {
    ProcSlot* s = proc_get(handle);
    if (!s) return proc_fail(EBADF);
    close(s->fd);
    if (!s->reaped) {
        int status;
        if (waitpid(s->pid, &status, WNOHANG) == s->pid) {
            s->reaped = 1;
            s->exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
        }
    }
    s->used = 0;
    return 0;
}

int id_proc_error(void) {
    return proc_last_errno;
}
