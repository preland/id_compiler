# `float` conformance cases

Each case pins down one semantic question about `id`'s `float` (C `double`).
Build and run with `IDC_NO_STD=1 bin/idc tests/conform/float/NN-name.id -o
/tmp/cf_out && /tmp/cf_out`; stdout must match `NN-name.expected` byte for
byte, and every case here exits 0 (no `.exit` file).

- `01-whole-value` — a whole-valued `float` (`2.0`) prints as `2`, not `2.0` — printing goes through `%g`, which drops a trailing `.0`.
- `02-one-third` — `1.0 / 3.0` prints as `0.333333`, `%g`'s default 6 significant digits, not a longer or shorter repeating expansion.
- `03-sum-precision` — `0.1 + 0.2` (`0.30000000000000004` in the underlying `double`) still *prints* as `0.3`, because `%g`'s 6-significant-digit rounding hides the binary-fraction error; the imprecision is real but invisible at this precision.
- `04-large-exponent` — a large value (`123456789.0`) prints in exponent form (`1.23457e+08`) once `%g` would need more than 6 significant digits, rather than the full decimal expansion.
- `05-div-by-zero-variants` — float division is IEEE, not a trap: `1.0 / 0.0` is `inf`, `(0.0 - 1.0) / 0.0` is `-inf`, and `0.0 / 0.0` is a NaN that this platform prints as `-nan` (glibc's `%g` shows the sign bit `0.0/0.0` happens to set, not a "positive" NaN).
- `06-div-by-negative` — dividing by a negative float (`1.0 / (0.0 - 2.0)`) gives the ordinary signed result (`-0.5`), no special-casing.
- `07-int-float-arith` — `int + float` widens the `int` operand and produces a `float` result (`3 + 2.0` prints `5`, not `5.0`, again because of `%g`).
- `08-int-float-compare` — `<` between an `int` and a `float` widens the `int` operand for the comparison (`3 < 4.0` is true) rather than being a type error.
- `09-float-in-list` — a `float[]` literal and indexing (`[1.5, 2.5, 3.0][1]`) round-trip the element's value exactly.
- `10-float-equality-imprecision` — `==` on `float` is bit-exact IEEE equality, not tolerance-based: `(0.1 + 0.2) == 0.3` is false even though both sides print identically as `0.3`.

**Cross-target note:** `05-div-by-zero-variants`'s `0.0 / 0.0` line is the one
case in this directory where `tests/conform.sh` disagrees across targets —
the C target (this directory's `.expected`, and what `bin/idc` builds) prints
`-nan`, but `idc.py --target llvm` prints `nan` (no leading `-`). Both are
valid encodings of "a NaN"; only the sign bit of the payload differs between
what C's `fdiv` and LLVM's `fdiv` happen to produce for `0.0/0.0` on this
machine. `--target wasm` cannot run any case that prints a `float` at all —
`print`/`+` on a `float` raises "float-to-string is not implemented for this
target" and is counted as a GAP, not a FAIL, matching the existing
`list/08-float-list-boxing` precedent.
