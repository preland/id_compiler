/* fs.h -- the C target's realisation of the `fs` backend ABI.
 *
 * The ABI itself lives in backend.json, written in `id`'s types, because it is
 * the part that is not about C: an interpreter or an LLVM target has to
 * provide the same eight functions with the same meanings, and reads them from
 * there. This header is one target's answer to that declaration -- the C
 * prototypes the object file exports -- and nothing above it (no `.id` file,
 * no compiler source) knows it exists.
 *
 * Why a backend at all, rather than builtins: adding `fs_*` to BUILTIN_NAMES
 * would mean implementing them once per code generator -- the C runtime, the
 * LLVM lowering, the wasm lowering -- and the C runtime is a string constant
 * inside `demos/idc_in_id_parse/back/out/sink/runtime.id`, so "add file
 * I/O" would have meant writing C into an `id` source file. As a backend the
 * implementation is C source in a C file, linked by whoever links.
 *
 * ABI notes (dictated by how idc links unknown functions -- see the README's
 * "Functions link across files"):
 *   - Every entry point is declared `extern int id_<name>()` by idc and called
 *     as `id_<name>(args)`. So each function is named with the `id_` prefix and
 *     returns `int`. A size or a count therefore tops out at INT_MAX, which is
 *     also true of every other length in `id` (`len` returns `int`).
 *   - Argument lowering mirrors idc's: `id` int -> C int, `id` string -> char*,
 *     `id` int[] -> IdList*.
 *
 * Why bytes cross as `int[]` rather than as an address in the flat store: the
 * store (`alloc`/`peek8`/`poke8`) is a `static` inside the *generated* program,
 * so a separately compiled object cannot reach it. A list is a pointer the id
 * side already owns and hands over -- the same seam gfx uses for a framebuffer.
 */
#ifndef ID_FS_H
#define ID_FS_H

/* Growable list, byte-for-byte identical to the IdList in idc.py's RUNTIME (and
 * to the one in gfx.h). An `id` `int[]` lowers to `IdList*`; each element is
 * one cell, and for an int list the cell holds the int directly. If idc's
 * runtime layout ever changes, this struct must change with it. */
typedef struct { int len, cap; long long* data; } IdList;

/* Open `path`. `mode` is one of "r", "w", "a" (a trailing "+" is accepted and
 * means read/write, as in C). Returns a handle >= 0, or -1 -- ask id_fs_error
 * for why. Handles are small integers, and there are FS_MAX_HANDLES of them. */
extern int id_fs_open(const char* path, const char* mode);

/* Read up to `n` bytes into `buf`, one byte per cell (0..255). `n` is clamped
 * to the list's length, so the caller sizes the buffer and the backend can
 * never write past it. Returns the number of bytes read -- 0 at end of file --
 * or -1 on error. Cells past the returned count are left alone. */
extern int id_fs_read(int handle, IdList* buf, int n);

/* Write the first `n` cells of `buf` as bytes (each cell is taken modulo 256).
 * `n` is clamped to the list's length. Returns the number of bytes written, or
 * -1 on error. */
extern int id_fs_write(int handle, IdList* buf, int n);

/* Flush and close a handle. Returns 0, or -1 (including for a handle that was
 * never open). */
extern int id_fs_close(int handle);

/* Size of `path` in bytes, or -1 if it cannot be stat'd. */
extern int id_fs_size(const char* path);

/* 1 if `path` exists, 0 if it does not. Never -1: "does it exist" has no
 * error case worth propagating. */
extern int id_fs_exists(const char* path);

/* Delete `path`. Returns 0, or -1. */
extern int id_fs_remove(const char* path);

/* The errno of the last fs_* call that returned -1, or 0 if none has. Reading
 * it does not clear it. This exists because every entry point returns `int`,
 * so a failure has exactly one bit of room to say so; the detail has to be
 * fetched separately. */
extern int id_fs_error(void);

#define FS_MAX_HANDLES 16

#endif /* ID_FS_H */
