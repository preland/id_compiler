Each case pins down one semantic question about `id`'s LIST system.

- `01-literal-len` — a list literal builds a list of the right length.
- `02-empty-literal-typed` — `[]` is legal (and has length 0) when the declared type pins the element type.
- `03-index-read-write` — indexing both reads and, on the left of `=`, writes the same underlying storage.
- `04-push-len` — `push` appends an element and `len` reflects the new count.
- `05-pop-shrinks` — `pop` returns the last element and shortens the list by one.
- `06-reference-semantics` — passing a list to a function passes the list itself; a mutation inside the callee is visible to the caller.
- `07-string-list` — lists work over `string` elements, not just `int`.
- `08-float-list-boxing` — a `float` pushed into a list and read back is bit-identical (round-trips through boxing correctly).
- `09-nested-lists` — `int[][]` indexes twice (`grid[i][j]`) for both read and write on the inner list.
- `10-two-levels` — a list reference stays live across two levels of function calls, not just one.
- `11-aliasing` — two local names bound to the same list are the same list: mutating through one name is visible through the other.

The next eleven cases are about loops the C target emits twice, a copy with its list accesses guarded once before the loop and the checked loop it falls back to (compiler/parse/back/tgt/c/emit/prog/code/body/fast/). Every one has the checked answer on every target, because a loop whose guard fails, or that the guard may not cover, is the checked loop: the earlier iterations' output, then the trap at the iteration the access first leaves the list, with the same message. The first five are loops the guard may cover, and are guarded on C and run checked on the LLVM target; the last six change something the guard compares, so are not covered and would read past the list if they were.

- `12-loop-bound-past-end` — `while(j < n)` over a list shorter than `n`: the first three sums are printed, then `id: index 3 out of bounds (len 3)`.
- `13-loop-store-past-end` — the same for a store: `out[i] = ...` writes the two cells there are, then traps on the third.
- `14-loop-negative-start` — a counter that starts below zero: the guard's `j >= 0` fails, the first iteration traps with `index -2`, after an earlier call over the same list printed its sum.
- `15-loop-copy-offset` — `xs[j + 1] = xs[j]` bounded by `len(xs)`: the offset is part of the guard, so the last iteration traps at index 3 where `xs[j]` alone would have been in range.
- `16-loop-in-range` — loops the guard does pass (an `int[]` and a `float[]` read together, a `float[]` scaled in place) give the right sums, and the access after them still traps.
- `17-loop-pop-in-body` — a `pop` in the body: the list is shorter on the third iteration, so `xs[j]` traps there instead of reading the cell `pop` removed.
- `18-loop-callee-pops` — the same, with the `pop` in a function the body calls.
- `19-loop-read-after-step` — a read after the counter has stepped: with `j < n` and `n` the length, the last iteration reads index 3.
- `20-loop-limit-grows` — a body that raises the limit it is bounded by: the guard's comparison of the limit with the length held only for the limit's first value.
- `21-loop-list-reassigned` — a body that reassigns the list to a shorter one: `xs[j]` on the second iteration is a different list's.
- `22-loop-cond-pops` — a call in the loop's condition that pops the list: the condition runs once per iteration, outside the body, so a loop whose condition is not plain comparisons is not covered, and traps on the third iteration.
