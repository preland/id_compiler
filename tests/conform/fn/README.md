# Function values

`func(T1, T2) return R` values: named top-level functions passed as
arguments, stored in locals and exports, and called through them
(docs/SPEC.md 1.1). C and LLVM only: `idc/idc.py`, which builds the WASM target,
has no function values (docs/SPEC.md 11, S12).
