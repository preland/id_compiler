# `fs` — files for `id`

`id` has no filesystem builtins. The whole of `BUILTIN_NAMES` gives a program
stdin (`input`, `read_all`) and stdout (`print`, `put`, `flush`) and nothing
else, so before this backend a program that worked on a file was a filter and
the *caller* chose the files:

```sh
./myprog < in.txt > out.txt      # the only file I/O id had
```

This backend supplies the missing nine functions at link time, the same way
`backends/gfx` supplies a window.

```sh
bin/idc demos/fsdemo -o fsdemo && ./fsdemo
```

## The seam

| function | meaning |
| --- | --- |
| `fs_open(path, mode)` | `mode` is `"r"`, `"w"` or `"a"` (`+` allowed). Returns a handle ≥ 0, or −1 |
| `fs_read(h, buf, n)` | up to `n` bytes into `buf`, one byte per cell. Returns the count, `0` at EOF, −1 on error |
| `fs_write(h, buf, n)` | the first `n` cells of `buf` as bytes. Returns the count, or −1 |
| `fs_close(h)` | flush and close. `0`, or −1 |
| `fs_size(path)` | bytes, or −1 |
| `fs_exists(path)` | `1` or `0` |
| `fs_remove(path)` | `0`, or −1 |
| `fs_list(path, buf, n)` | the directory's entries into `buf`, newline-separated, a directory ending in `/`. Returns the bytes the listing *needs* — grow and retry if that exceeds `n` — or −1 |
| `fs_error()` | the `errno` of the last call that returned −1 |
| `fs_run(cmd)` | run `cmd` through a shell; its exit status, or −1 if it could not be started |

`n` is clamped to `len(buf)`, so the caller sizes the buffer and the backend
can never write past it — the same contract as every other bounds check in the
runtime.

### Why bytes cross as `int[]`

`id` has a flat byte store (`alloc`/`peek8`/`poke8`) that would be the obvious
buffer, but it is a `static` inside the *generated program*: a separately
compiled object cannot reach it. A list is a pointer the `id` side already owns
and hands over, which is the seam `gfx` already uses for a framebuffer. One
byte per 8-byte cell is wasteful and completely portable; a store-addressed
fast path can be added later without changing these names.

### Why every function returns `int`

`idc` resolves a call to an undefined function as `extern int id_<name>()`,
satisfied at link time. So a failure has exactly one bit of room to say so —
hence −1 everywhere, and `fs_error()` to fetch the detail.

**`fs_error` reads state that the failing call sets, so keep them in separate
statements.** Operands of one expression are not ordered, and
`"gave " + fs_open(p, "r") + ", errno " + fs_error()` may well ask for the
reason before there is one. (It did, in the first draft of `demos/fsdemo` —
the errno printed as `0`.) One call per statement, and the order is the order.

`fs_run` is the odd one out: it is not about a file, and it is `system`, so the
string it is given reaches a shell. It exists because a program that can *write*
a project and not *build* it stops halfway — the editor writes a game's sources
and then has to invoke the packer, and `id` can spawn a process no other way. A
caller composing the command from untrusted text is composing a shell injection;
the callers that exist compose it from paths their own user chose.

## What is *not* here

No `stat` beyond size/existence, no seek, no rename, no permissions. The list
above is what a program needs to read a file, write a file, walk a tree of them,
and know whether it worked; everything else is an addition to `backend.json`'s
`abi` when something actually needs it.

`fs_list` was added for one reason: `bin/idc` is a bash script because a
compiler that reads its own source tree needs `readdir`, not `fopen`, and until
this call existed `id` had no way to ask what a directory contains. That is the
last thing the driver did that `id` could not.

## Compiler-agnostic by construction

Nothing about C appears above the object file. `demos/fsdemo` calls `fs_open`
the way it calls any other function; `conf.id` says where those functions
come from; and `backend.json` declares the contract in `id`'s own types:

```json
{ "name": "fs",
  "abi": [ { "name": "fs_open", "params": ["string", "string"], "returns": "int" }, … ],
  "targets": {
    "c": { "header": "fs.h",
           "platforms": { "linux":  { "sources": ["fs_posix.c"], "cflags": [], "link": [] },
                          "darwin": { "sources": ["fs_posix.c"], "cflags": [], "link": [] } } } } }
```

The split is the point. `abi` is about `id` and is the same however the program
is compiled. `targets` is about a *code generator*: the C target wants sources,
cflags and link flags; an LLVM target, a wasm target, or an interpreter wants
something else and adds its own key beside `"c"`. Adding one changes this file
and the driver that reads it — **no `.id` file, in this backend or in any
program that uses it**.

Both compilers read the `targets` layer (`idc.py`'s `backend_platforms`, and
the same logic inline in `bin/idc`). A manifest with no `targets` at all — `gfx`
and `gl` — has a bare `platforms` table, which is read as the C target's, so
the older backends keep working unchanged.

The C target does not currently *use* the `abi` declaration: it emits
unprototyped externs and lets the linker match them, so it never needs to know
a signature. It is declared anyway because a target that binds natively — an
interpreter mapping `fs_read` to a host function, say — cannot parse `fs.h` to
find out, and because it is the only machine-readable statement of what this
backend promises.

## Portability

`fs_posix.c` is buffered stdio and `stat`, which is why one file serves both
platform keys. A host that needs something else (a kernel target with no libc)
adds its own source under `targets.c.platforms`, and nothing above it moves.
