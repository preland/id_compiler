/* sock.h -- the `id` Unix-domain-socket backend ABI (Linux only).
 *
 * QMP -- the protocol tools/qmon speaks to QEMU -- is JSON lines over a
 * Unix-domain socket, and the socket does not exist until QEMU has booted
 * far enough to create it. `id` has no socket of any kind, so this backend
 * is the missing seam: connect (retrying until the path appears), send,
 * receive with a timeout, close.
 *
 * ABI notes, matching backends/fs/fs.h and backends/proc/proc.h:
 *   - Every entry point is a `native` declaration in this directory's .id
 *     files, named with the `id_` prefix, returning `int`; id_sock_error()
 *     fetches the errno behind a -1.
 *   - Argument lowering mirrors idc's: `id` int -> C int, `id` string ->
 *     char*, `id` int[] -> IdList* (below).
 *   - Bytes cross as `int[]`, one byte per cell, for the same reason fs_read
 *     and proc_read do: the flat store is unreachable from a separately
 *     compiled object.
 */
#ifndef ID_SOCK_H
#define ID_SOCK_H

/* Growable list, byte-for-byte identical to the IdList in idc.py's RUNTIME
 * (and to backends/fs/fs.h's and backends/proc/proc.h's copies). An `id`
 * `int[]` lowers to `IdList*`. */
typedef struct { int len, cap; long long* data; } IdList;

/* Connect to the Unix-domain socket at `path`, retrying while it does not
 * exist yet or refuses connections, for up to `timeout_ms`. Returns a
 * handle >= 0, or -1 -- ask id_sock_error for why (ETIMEDOUT if the
 * deadline passed). */
extern int id_sock_connect(const char* path, int timeout_ms);

/* Send the first `n` cells of `buf` as bytes. `n` is clamped to the list's
 * length. Returns the number of bytes sent, or -1. */
extern int id_sock_send(int handle, IdList* buf, int n);

/* Receive up to `n` bytes into `buf`, one byte per cell, waiting up to
 * `timeout_ms` for at least one byte to arrive. `n` is clamped to the
 * list's length. Returns the number of bytes read, 0 if none arrived within
 * the timeout (which includes the peer having closed the connection), or
 * -1 on error. */
extern int id_sock_recv(int handle, IdList* buf, int n, int timeout_ms);

/* Close the handle. Returns 0, or -1 (including for a handle that was
 * never open). */
extern int id_sock_close(int handle);

/* The errno of the last sock_* call that returned -1, or 0 if none has.
 * Reading it does not clear it. */
extern int id_sock_error(void);

#define SOCK_MAX_HANDLES 8

#endif /* ID_SOCK_H */
