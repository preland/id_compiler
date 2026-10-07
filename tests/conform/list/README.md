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

The next fourteen are about the same loops with an index that is more than `j` or `j + k` (fast/idx/): a sum of literals, names the body leaves alone, counters of the condition, a second counter stepped once per iteration, and a local the body sets once. The guard compares the largest value of the index with the length, in 64 bits, and a loop it cannot cover is the checked loop, so each case ends with the trap the checked loop gives, at the iteration the index leaves the list.

- `23-loop-affine-past-end` — `xs[j * 3 + 1]` over seven cells with `n` of 3: the third iteration's index is 7.
- `24-loop-affine-in-range` — a stride and offset that are parameters, a store through `2 * j + 1`, and a negative stride (the guard's `w >= 0` fails and the checked loop gives the right sum); then the same read with an offset that leaves the list.
- `25-loop-derived-past-end` — `int q = j * 7;` then `xs[q + 3]`: the sum of two iterations is in range, three is not (index 17).
- `26-loop-derived-after-step` — the same local set after the counter has stepped: `q` is `(j + 1) * 2`, a value the loop bound alone does not limit, so the last iteration reads index 6 of six cells.
- `27-loop-counter-past-end` — `dst[k] = src[j]` with `k` a second counter that starts at 3 and a `dst` that holds one cell fewer than the copy needs.
- `28-loop-counter-merge` — a merge of two sorted lists into a third, the shape of the `sortb` benchmark: two counters in the condition, one stepped in each arm of an `if`, the third counter stepped after the store; the full-size output is right and an output one cell short traps in the tail.
- `29-loop-counter-idle-turns` — an iteration that steps no counter of the condition (one arm of the `if` only changes a flag): more iterations than the counters' room, so `k` passes the end and the store traps at index 4.
- `30-loop-counter-step-first` — `k` stepped before the store: the store at the last iteration is one past what the condition's room suggests.
- `31-loop-counter-step-by-two` — `k = k + 2` is not a step by one, so the iteration count does not bound it.
- `32-loop-affine-wraps` — `xs[j * 65536 + 1]` with `n` of 65537: the stride times `n - 1` is 2^32 plus one, which wraps to 1 in 32 bits and would pass; the guard does it in 64 and falls back to the checked loop, which traps on the second iteration.
- `33-loop-counter-negative-start` — a second counter that starts at -1: the guard's `k >= 0` fails and the first store traps with `index -1`.
- `34-loop-offset-grows` — `xs[j + c]` with `c` raised by 5 each iteration: a name the body writes is not a term the guard may read once, so the third iteration's index 12 traps.
- `35-loop-offset-negative` — `xs[j + c]` with `c` of -2: a term must not be negative, so the guard's `c >= 0` fails and the first read traps at index -2.
- `36-loop-index-unchanging` — an index that is a name the body leaves alone (`xs[c]`): in range, the loop gives its sum; one past the end, the guard fails, so the first iteration prints its line and then traps at index 3, as the checked loop does.
