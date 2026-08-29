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
- `13-operator-precedence` — one expression per precedence question: `*` before `+` before `<<`; left-associativity of `-`; `&` before `^` before `|`; bitwise operators bind tighter than `==`; `&&` binds tighter than `||`.
- `14-binary-literals` — `0b` literals lex to the same integer values as decimal and participate in arithmetic normally.
