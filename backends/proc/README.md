# `proc` — child processes for `id`

`id` has no way to start another process and watch it run. `fs_run` (in
`backends/fs`) can run a command, but only to completion, with no handle, no
timeout and no way to kill it early -- fine for "build this," useless for
"start QEMU, talk to it while it runs, and stop it when done," which is what
`tools/qmon` needs.

This backend supplies that: spawn, read what the child writes to stdout,
wait for it with a timeout, kill it.

```sh
bin/idc demos/procdemo -o procdemo && ./procdemo
```

## The seam

| function | meaning |
| --- | --- |
| `proc_spawn(argv_lines)` | start a child; `argv_lines` is the program and its arguments, one per line (see below). Returns a handle ≥ 0, or −1 |
| `proc_read(h, buf, n, timeout_ms)` | up to `n` bytes of the child's stdout into `buf`, waiting up to `timeout_ms` for at least one. Returns the count, `0` if none arrived (including the child having closed stdout), or −1 |
| `proc_wait(h, timeout_ms)` | wait up to `timeout_ms` for the child to exit. Returns its exit status (0..255, or 128+signal), or −1 (`proc_error()` is `ETIMEDOUT` if it is still running) |
| `proc_kill(h)` | send `SIGKILL`. `0`, or −1. Does not reap -- call `proc_wait` after |
| `proc_close(h)` | close the stdout pipe and reap the child if it has already exited (never blocks). `0`, or −1 |
| `proc_error()` | the `errno` of the last call that returned −1 |

`n` is clamped to `len(buf)`, so the caller sizes the buffer and the backend
can never write past it -- the same contract as `fs_read`.

The child's stdin and stderr are both `/dev/null`. Nothing here lets `id`
write to a child's stdin; `tools/qmon` never needs to, and adding it costs a
native this backend does not otherwise need.

### Why `argv_lines` is one string, not a `string[]`

idc's native boundary lowers `int`, `int[]` and a single `string` (see
`backends/gfx/gfx.h` and `backends/gl/gl.h`: "there is no `id` string arg on
this second tier except the window title"). A `string[]` has no lowering at
all -- an `IdList` cell is one uniform 64-bit word, and a string is not one.
So the caller builds one string with idstd's `str_join(argv, "\n")` -- the
program name, then each argument, one per line -- and this backend splits it
back on `\n`. None of `tools/qmon`'s arguments can contain a newline (they
are flag names, file paths and a fixed QEMU command line), so the join loses
nothing. A caller that needs a literal newline in an argument cannot use this
backend as it stands; nothing in this repository does.

### Why bytes cross as `int[]`

Same reason as `fs_read`: the flat store (`alloc`/`peek8`/`poke8`) is a
`static` inside the *generated* program, unreachable from a separately
compiled object. A list is a pointer the `id` side already owns and hands
over.

## What is *not* here

No writing to a child's stdin, no reading its stderr separately (it goes to
`/dev/null`), no process groups, no signals besides `SIGKILL`. This is the
smallest seam `tools/qmon` needs; a caller that needs more adds one more
`native` declaration beside these, and its C, when something actually needs
it.

## Portability

Linux only. `fork`, `execvp`, `pipe`, `waitpid` and `kill` are POSIX, but the
retry-with-timeout shape of `proc_wait` was only proven on Linux, so
`backend.id` declares no darwin sources; the compiler's missing-platform
diagnostic (`docs/BACKENDS.md`) names the gap exactly if something reaches a
`proc_*` native while building for another platform.
