# `sock` — Unix-domain sockets for `id`

`id` has no socket of any kind. QMP -- the protocol `tools/qmon` speaks to
QEMU -- is JSON lines over a Unix-domain socket that does not exist until
QEMU has booted far enough to create it, and the same tool reads a second
such socket (the guest's serial port) while QEMU runs. Neither is possible
without this backend.

```sh
bin/idc demos/sockdemo -o sockdemo && ./sockdemo
```

## The seam

| function | meaning |
| --- | --- |
| `sock_connect(path, timeout_ms)` | connect to the socket at `path`, retrying while it does not exist yet or refuses connections, for up to `timeout_ms`. Returns a handle ≥ 0, or −1 (`sock_error()` is `ETIMEDOUT` past the deadline) |
| `sock_send(h, buf, n)` | send the first `n` cells of `buf` as bytes. Returns the count, or −1 |
| `sock_recv(h, buf, n, timeout_ms)` | up to `n` bytes into `buf`, waiting up to `timeout_ms` for at least one. Returns the count, `0` if none arrived (including the peer having closed the connection), or −1 |
| `sock_close(h)` | `0`, or −1 |
| `sock_error()` | the `errno` of the last call that returned −1 |

`n` is clamped to `len(buf)`, the same contract as `fs_read` and `proc_read`.

### Why `sock_connect` retries

QEMU creates the QMP and serial sockets as it starts; a caller that connects
the instant it spawns the process finds nothing there yet. `ENOENT` (the
path does not exist) and `ECONNREFUSED` (it exists but nothing is listening)
are retried, with a short sleep between attempts, until the deadline; any
other error (a bad path, permission denied) is reported immediately rather
than retried to a timeout that could never have helped.

### Why bytes cross as `int[]`

Same reason as `fs_read` and `proc_read`: the flat store is a `static`
inside the *generated* program, unreachable from a separately compiled
object.

## What is *not* here

No datagram sockets, no TCP, no listening (`id` is always the client here).
This is the smallest seam `tools/qmon` needs; a caller that needs more adds
one more `native` declaration beside these, and its C, when something
actually needs it.

## Portability

Linux only. `AF_UNIX` `SOCK_STREAM` sockets are POSIX, but the retry loop in
`sock_connect` was only proven on Linux, so `backend.id` declares no darwin
sources; the compiler's missing-platform diagnostic (`docs/BACKENDS.md`)
names the gap exactly if something reaches a `sock_*` native while building
for another platform.
