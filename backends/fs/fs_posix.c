/* fs_posix.c -- the `fs` backend for POSIX hosts (Linux, macOS).
 *
 * Ordinary buffered stdio behind the eight entry points in fs.h. There is no
 * platform-specific code here beyond stdio itself, which is why one file
 * serves both platform keys in backend.json; a host that needs something else
 * (a kernel target with no libc, say) adds its own source there without
 * touching this one or any `id` file.
 *
 * Everything is bounds-checked in the same spirit as the rest of the runtime:
 * a bad handle is a clean -1, never a wild FILE* dereference, and a read can
 * never write past the list the caller supplied.
 */
#include "fs.h"

#include <errno.h>
#include <stdlib.h>   /* system */
#include <stdio.h>
#include <sys/stat.h>

static FILE* fs_handles[FS_MAX_HANDLES];
static int fs_last_errno = 0;

/* Record why a call is about to return -1, and return it. Every failure path
 * goes through here so id_fs_error is never stale in one place and fresh in
 * another. */
static int fs_fail(int err) {
    fs_last_errno = err;
    return -1;
}

static FILE* fs_get(int handle) {
    if (handle < 0 || handle >= FS_MAX_HANDLES) return NULL;
    return fs_handles[handle];
}

/* Accept exactly the modes the ABI documents, plus the "+" variants. Anything
 * else is rejected here rather than handed to fopen, whose behaviour on an
 * unrecognised mode string is implementation-defined. */
static int fs_mode_ok(const char* mode) {
    if (!mode || (mode[0] != 'r' && mode[0] != 'w' && mode[0] != 'a')) return 0;
    if (mode[1] == '\0') return 1;
    return mode[1] == '+' && mode[2] == '\0';
}

int id_fs_open(const char* path, const char* mode) {
    if (!path || !fs_mode_ok(mode)) return fs_fail(EINVAL);
    for (int h = 0; h < FS_MAX_HANDLES; h++) {
        if (fs_handles[h]) continue;
        /* "b" is a no-op on POSIX and the right thing everywhere else: id
           reads bytes, not lines, so no newline translation may happen. */
        char m[4];
        snprintf(m, sizeof m, "%sb", mode);
        FILE* f = fopen(path, m);
        if (!f) return fs_fail(errno);
        fs_handles[h] = f;
        return h;
    }
    return fs_fail(EMFILE);
}

int id_fs_read(int handle, IdList* buf, int n) {
    FILE* f = fs_get(handle);
    if (!f || !buf) return fs_fail(EBADF);
    if (n < 0) return fs_fail(EINVAL);
    if (n > buf->len) n = buf->len;      /* the caller owns the buffer's size */
    int got = 0;
    while (got < n) {
        int c = fgetc(f);
        if (c == EOF) break;
        buf->data[got++] = (long long)(unsigned char)c;
    }
    if (got == 0 && ferror(f)) return fs_fail(errno);
    return got;
}

int id_fs_write(int handle, IdList* buf, int n) {
    FILE* f = fs_get(handle);
    if (!f || !buf) return fs_fail(EBADF);
    if (n < 0) return fs_fail(EINVAL);
    if (n > buf->len) n = buf->len;
    for (int i = 0; i < n; i++) {
        if (fputc((int)(buf->data[i] & 0xff), f) == EOF) return fs_fail(errno);
    }
    return n;
}

int id_fs_close(int handle) {
    FILE* f = fs_get(handle);
    if (!f) return fs_fail(EBADF);
    fs_handles[handle] = NULL;
    if (fclose(f) != 0) return fs_fail(errno);
    return 0;
}

int id_fs_size(const char* path) {
    struct stat st;
    if (!path) return fs_fail(EINVAL);
    if (stat(path, &st) != 0) return fs_fail(errno);
    /* Every length in id is an int; a file too big to describe is an error
       rather than a wrapped-around size the caller would use as a count. */
    if (st.st_size > 0x7fffffff) return fs_fail(EFBIG);
    return (int)st.st_size;
}

int id_fs_exists(const char* path) {
    struct stat st;
    if (!path) return 0;
    return stat(path, &st) == 0 ? 1 : 0;
}

int id_fs_remove(const char* path) {
    if (!path) return fs_fail(EINVAL);
    if (remove(path) != 0) return fs_fail(errno);
    return 0;
}

/* Run a shell command and answer its exit status, or -1 if it could not be run
 * at all. This is the seam's one capability that is not about *files*, and it is
 * here rather than in a backend of its own because a program that can write a
 * file and not build it is a program that stops halfway: the editor writes a
 * game's sources and then has to invoke the packer, and `id` cannot spawn a
 * process by any other route.
 *
 * It is `system`, with everything that implies -- the string reaches a shell, so
 * a caller composing one from untrusted text is composing a shell injection. The
 * callers here compose from paths the user themselves chose in the editor, which
 * is the same trust boundary as the editor's own argv. */
int id_fs_run(const char* cmd) {
    int rc;
    if (!cmd || !*cmd) return fs_fail(EINVAL);
    rc = system(cmd);
    if (rc == -1) return fs_fail(errno);
    return rc;
}

int id_fs_error(void) {
    return fs_last_errno;
}
