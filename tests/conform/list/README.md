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
