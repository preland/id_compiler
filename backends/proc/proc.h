/* proc.h -- the `id` child-process backend ABI (Linux only).
 *
 * The whole of `BUILTIN_NAMES` gives a program stdin, stdout and a filesystem
 * (through `fs`) but no way to start another process and watch it run, so a
 * tool that has to drive something long-lived -- QEMU, in `tools/qmon` --
 * could not exist in `id` at all. This backend is the missing seam: spawn,
 * read what it writes, wait for it with a timeout, kill it.
 *
 * ABI notes, matching backends/fs/fs.h:
 *   - Every entry point is a `native` declaration in this directory's .id
 *     files, so it is named with the `id_` prefix and returns `int`: a status
 *     fits one bit of room, hence -1 everywhere and id_proc_error() to fetch
 *     the errno behind it.
 *   - Argument lowering mirrors idc's: `id` int -> C int, `id` string ->
 *     char*, `id` int[] -> IdList* (below).
 *
 * Why argv is one newline-joined string rather than a `string[]`: idc's
 * native boundary only lowers int, int[] and a single string (see gfx.h and
 * gl.h -- "there is no id string arg on this second tier except the window
 * title"); a list of strings has no lowering at all, because an IdList cell
 * is one uniform 64-bit word and a string is not one. The caller builds the
 * line with idstd's str_join(argv, "\n"); this side splits on '\n'. None of
 * qmon's arguments can contain a newline, so the join is lossless.
 *
 * Why bytes read from the child cross as `int[]`: the same reason fs_read
 * does (fs.h) -- the flat store is a `static` inside the *generated* program,
 * unreachable from a separately compiled object, so a list the id side
 * already owns is the seam.
 */
#ifndef ID_PROC_H
#define ID_PROC_H

/* Growable list, byte-for-byte identical to the IdList in idc.py's RUNTIME
 * (and to backends/fs/fs.h's copy). An `id` `int[]` lowers to `IdList*`. */
typedef struct { int len, cap; long long* data; } IdList;

/* Start `argv_lines` (the program name, then its arguments, one per line) as
 * a child process. Its stdin is /dev/null, its stderr is /dev/null, its
 * stdout is a pipe this backend reads with id_proc_read. Returns a handle
 * >= 0, or -1 -- ask id_proc_error for why. */
extern int id_proc_spawn(const char* argv_lines);

/* Read up to `n` bytes of the child's stdout into `buf`, one byte per cell,
 * waiting up to `timeout_ms` for at least one byte to arrive. `n` is clamped
 * to the list's length. Returns the number of bytes read, 0 if none arrived
 * within the timeout (which includes the child having closed its stdout),
 * or -1 on error. */
extern int id_proc_read(int handle, IdList* buf, int n, int timeout_ms);

/* Wait up to `timeout_ms` for the child to exit. Returns its exit status
 * (0..255, or 128+signal if it was killed by one) if it exited in time, or
 * -1 -- ask id_proc_error for why, which is ETIMEDOUT if it is still
 * running. Calling it again after a successful wait returns the same status
 * without touching the child again. */
extern int id_proc_wait(int handle, int timeout_ms);

/* Send SIGKILL to the child. Returns 0, or -1. Does not reap it -- follow
 * with id_proc_wait to collect the exit status. */
extern int id_proc_kill(int handle);

/* Close the handle: closes the stdout pipe and reaps the child if it has
 * already exited, without blocking if it has not. Returns 0, or -1
 * (including for a handle that was never open). */
extern int id_proc_close(int handle);

/* The errno of the last proc_* call that returned -1, or 0 if none has.
 * Reading it does not clear it. */
extern int id_proc_error(void);

#define PROC_MAX_HANDLES 8

#endif /* ID_PROC_H */
