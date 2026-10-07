# `int` arithmetic conformance cases

Each case pins down one semantic question about `id`'s 32-bit `int`. Build and
run with `IDC_NO_STD=1 bin/idc tests/conform/int/NN-name.id -o /tmp/cc_out &&
/tmp/cc_out`; stdout must match `NN-name.expected` byte for byte, and every
case here exits 0 (no `.exit` file).

- `01-add-overflow-wrap` — `2147483647 + 1` wraps to `INT_MIN` (`-2147483648`) instead of trapping or promoting.
- `02-mul-overflow-wrap` — `100000 * 100000` (which is `10000000000`, past `INT_MAX`) wraps to a 32-bit two's-complement value instead of trapping.
- `03-div-truncates-toward-zero` — `/` on `int` truncates toward zero for every sign combination, not toward negative infinity.
- `04-mod-follows-dividend-sign` — `%`'s sign follows the dividend (C convention), not the divisor, for every sign combination.
- `05-shift-left-counts` — `<<` at counts 0, 31 (fills the sign bit), 32, and 35: counts at or past the 32-bit width give 0 rather than wrapping the count mod 32.
- `06-shift-right-arith-counts` — `>>` (arithmetic/sign-propagating) at counts 0, 31, 32, 35 on both a negative and a positive value: past the width it saturates to the sign (`-1` or `0`) rather than wrapping the count mod 32.
- `07-bitwise-and-or-xor` — `&`, `|`, `^` compute the expected bitwise result on plain `int` operands.
- `08-bitwise-not` — `~` is two's-complement bitwise NOT (`~x == (0 - x) - 1`).
- `09-logical-and-or` — `&&`/`||` evaluate to `0`/`1` regardless of the operands' magnitude (any nonzero operand is truthy).
- `10-logical-not` — `!` maps `0` to `1` and any nonzero value to `0`.
- `11-comparison-operators` — `<`, `<=`, `>`, `>=`, `==`, `!=` all produce `int` `0`/`1`.
- `12-hex-literals` — `0x` literals lex to the same integer values as decimal and participate in arithmetic normally.
- `13-operator-precedence` — one expression per precedence question: `*` before `+` before `<<`; left-associativity of `-`; `&` before `^` before `|`; a parenthesized bitwise operand of `==`; `&&` binds tighter than `||`. Mixing a bitwise operator and a comparison without parentheses is a compile error in `bin/idc`, so which binds tighter is no longer a question a program can ask.
- `14-binary-literals` — `0b` literals lex to the same integer values as decimal and participate in arithmetic normally.
- `15-comparison-bitwise-parenthesized` — both groupings of a bitwise operator and a comparison, written with the parentheses the language requires, give the same answer on every target: `(6 & 3) == 2` is `1` and `6 & (3 == 2)` is `0`.
- `17-negative-constants` — a `conf.id` scalar or list constant written with a unary `-` or `~` (`-5`, `-(-5)`, `-0x10`, `~5`) holds that value on every target. `--target llvm` once emitted `@k = global i32 -`, which does not assemble. A project, not a single file, because constants live in `conf.id`.
- `18-overflow-not-assumed` — `x + 1 > x` at `x == INT_MAX` is `0`: the comparison sees the wrapped sum. A C compiler that assumes signed overflow cannot happen folds it to `1`, so this is what fails if the C target loses `-fwrapv` (nixpkgs' gcc wrapper adds `-fno-strict-overflow` on its own, which hides that; `gcc -O2 -fstrict-overflow` on the emitted C shows it).
- `19-word-top-bit` — a `word` literal of 2^63 or more (`0x8000000000000000`, `0xFFFFFFFFFFFFFFFF`) equals a `word` holding the same bits. The C target once wrote it as decimal `LL`, which gcc reads as a 128-bit constant, so the comparison was false there and true on LLVM.
