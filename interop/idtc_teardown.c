/* idtc_teardown.c -- the test harness's per-case cleanup, compiled apart from it.

   The harness is one translation unit, linked into one executable, that also
   holds the program's own global variables, which the C target emits under
   their own names (functions are id_-prefixed; globals are not). That makes
   every libc name the teardown touches a name a program may define, twice
   over: the declaration (a program with `export int[] fstat` stopped building
   the moment <sys/stat.h> came in) and the symbol (a global called `opendir`
   or `poll` is resolved by a call to the libc function of that name, and the
   call lands on the variable). So the teardown includes the headers it needs
   here, not in the harness, which sees only the idtc_-prefixed prototypes
   below; and it reaches the kernel through syscall(2) alone, naming no other
   libc function.

   idtc_rmtree removes a case's scratch directory with everything in it.
   idtc_pull reads the case's stderr pipe while the case is alive and then
   drains what is left, without waiting for an end of file that a child the
   case left running would never send. idtc_nonblock makes the counts pipe
   non-blocking for the final read. Linux only, as the harness's process-group
   teardown already is. */

#define _GNU_SOURCE
#include <stddef.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>

struct idtc_dirent {
    unsigned long long ino;
    long long off;
    unsigned short reclen;
    unsigned char type;
    char name[1];
};

static int idtc_dots(const char* s) {
    return s[0] == '.' && (s[1] == '\0' || (s[1] == '.' && s[2] == '\0'));
}

static size_t idtc_join(char* out, size_t cap, const char* dir, const char* name) {
    size_t n = 0;
    while (*dir && n + 1 < cap) out[n++] = *dir++;
    if (n + 1 < cap) out[n++] = '/';
    while (*name && n + 1 < cap) out[n++] = *name++;
    out[n] = '\0';
    return n;
}

void idtc_rmtree(const char* dir) {
    char buf[8192];
    char sub[4096];
    long got;
    int fd;
    syscall(SYS_fchmodat, AT_FDCWD, dir, 0700, 0);
    fd = (int)syscall(SYS_openat, AT_FDCWD, dir, O_RDONLY | O_DIRECTORY, 0);
    if (fd >= 0) {
        while ((got = syscall(SYS_getdents64, fd, buf, sizeof buf)) > 0) {
            long at = 0;
            while (at < got) {
                struct idtc_dirent* e = (struct idtc_dirent*)(buf + at);
                at += e->reclen;
                if (idtc_dots(e->name)) continue;
                idtc_join(sub, sizeof sub, dir, e->name);
                if (syscall(SYS_unlinkat, AT_FDCWD, sub, 0) != 0) idtc_rmtree(sub);
            }
        }
        syscall(SYS_close, fd);
    }
    syscall(SYS_unlinkat, AT_FDCWD, dir, AT_REMOVEDIR);
}

size_t idtc_pull(int fd, char* msg, size_t used, int ms, pid_t pid) {
    char chunk[512];
    siginfo_t wi;
    struct pollfd pf;
    struct timespec ts;
    long r;
    long pr;
    size_t i;
    pf.fd = fd;
    pf.events = POLLIN;
    pf.revents = 0;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    for (;;) {
        pr = syscall(SYS_ppoll, &pf, 1, &ts, NULL, 0);
        if (pr < 0 && errno == EINTR) continue;
        if (pr < 0) break;
        if (pr == 0) {
            wi.si_pid = 0;
            if (pid <= 0) break;
            if (syscall(SYS_waitid, P_PID, (id_t)pid, &wi, WEXITED | WNOHANG | WNOWAIT, NULL) == 0 && wi.si_pid != 0) break;
            continue;
        }
        r = syscall(SYS_read, fd, chunk, sizeof chunk);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) break;
        if ((size_t)r > 4095 - used) r = (long)(4095 - used);
        for (i = 0; i < (size_t)r; i++) msg[used + i] = chunk[i];
        used += (size_t)r;
    }
    return used;
}

void idtc_nonblock(int fd) {
    syscall(SYS_fcntl, fd, F_SETFL, O_NONBLOCK);
}
