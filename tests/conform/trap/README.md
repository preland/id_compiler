# Trap conformance cases

Each case pins down one runtime abort: `id` aborts with a one-line message on
stderr and exit code 1, instead of silently corrupting memory or hitting
undefined C behaviour. Build and run with `IDC_NO_STD=1 bin/idc
tests/conform/trap/NN-name.id -o /tmp/cc_out && /tmp/cc_out`; stdout must
match `NN-name.expected` (empty in every case here, since the trap fires
before any `print`), the exit code must match `NN-name.exit`, and stderr must
match `NN-name.stderr` exactly.

- `01-div-zero` — `int` division by a runtime-computed zero traps with `id: division by zero` instead of raising SIGFPE.
- `02-mod-zero` — `int` remainder by a runtime-computed zero traps with `id: remainder by zero` instead of raising SIGFPE.
- `03-list-index-oob` — reading a list index past its length traps with `id: index N out of bounds (len L)` instead of reading out-of-bounds memory.
- `04-pop-empty` — `pop` on an empty list traps with `id: pop from empty list` instead of underflowing.
- `05-store-oob` — a flat-store `peek64` past the store's high-water mark traps with `id: store address A out of range (size S)` instead of reading unmapped/stale memory.
