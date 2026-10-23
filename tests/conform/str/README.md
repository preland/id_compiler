# `string` conformance cases

Each case pins down one semantic question about `id`'s `string`. Build and
run with `IDC_NO_STD=1 bin/idc tests/conform/str/NN-name.id -o /tmp/cf_out &&
/tmp/cf_out`; stdout must match `NN-name.expected` byte for byte, and every
case here exits 0 (no `.exit` file).

- `01-concat` — `+` between two strings concatenates them.
- `02-plus-int-both-sides` — `+` with an `int` operand on either side of a `string` converts the `int` and concatenates (`"lucky " + 7` and `7 + " lucky"` both work).
- `03-plus-float` — `+` with a `float` operand converts it via the same `%g` formatting `print` uses (`"pi is " + 3.5` → `"pi is 3.5"`).
- `04-len-empty-and-nonempty` — `len("")` is `0` and `len("hello")` is `5`; empty and non-empty strings both measure correctly.
- `05-character_code_at-in-range-and-zero` — `character_code_at` at index `0` and at a middle index return the byte's ASCII code (`'h'` → `104`, `'l'` → `108`), not the character itself.
- `06-character_code_at-past-end-and-negative` — `character_code_at` past the end of the string (index `5` on a 2-byte string) and at a negative index (`0 - 1`) both return `-1` rather than trapping.
- `07-chr-roundtrip` — `chr(65)` builds `"A"`, and `character_code_at` on that string recovers `65`: `chr`/`character_code_at` round-trip.
- `08-to-int-numeric` — `to_int` parses an ordinary positive number (`"42"` → `42`) and a negative one (`"-7"` → `-7`).
- `09-to-int-non-numeric` — `to_int` on a non-numeric string (`"banana"`) and on `""` both give `0` (it's `atoi` underneath: no error, just `0` on anything with no leading digits).
- `21-to-int-space-sign-junk` — `to_int` skips leading whitespace (space, tab, newline), takes one optional `+`/`-`, stops at the first non-digit (`"  -12abc"` → `-12`, `"12 34"` → `12`), and gives `0` when a sign is not followed by a digit (`"- 5"`, `"-"`, `"+"`).
- `22-to-int-overflow` — `to_int` keeps `atoi` semantics past `int`: the value saturates at the 64-bit limits, then the low 32 bits are the result (`"2147483648"` → `-2147483648`, `"4294967297"` → `1`, `"9223372036854775808"` → `-1`, `"-9223372036854775809"` → `0`).
- `23-scan-loop-in-range` — a `while (i < len(s))` loop reading `character_code_at(s, i)` counts the commas of `",a,bc,,d,"` (5; the leading comma catches a read one byte off); on the C target this loop takes the bounds-hoisted fast copy, which reads the byte unchecked.
- `24-scan-loop-past-end` — the same scan with a limit two past `len(s)` stays on the checked copy, so the two reads past the end answer `-1`: `97 + 98 - 1 - 1` is 193.
- `10-equality` — `==` on two strings with equal contents (distinct literals, same characters) is true.
- `11-inequality` — `!=` on two strings with different contents is true.
- `12-backslash-and-quote-escape` — a string literal with `\\` and `\"` escapes (`"back\\slash and \"quote\""`) prints the literal backslash and quote characters, not the escape sequences.

**Ordering comparison is not supported and is a compile error, not a runtime
answer**, so it has no `.id`/`.expected` pair here (there is no program to
run). Confirmed directly:

```
main(int argc, string[] argv) {
  string a = "cat";
  string b = "dog";
  if (a < b) {
    print("less");
  }
} return int 0;
```

fails to build, from both `bin/idc` and `idc.py`, with:

```
error: cannot order string and string
```

`==`/`!=` are the only comparisons `string` supports (see `10-equality` and
`11-inequality`); `<`, `<=`, `>`, `>=` are numeric-only (`is_numeric(lt) and
is_numeric(rt)` in `idc.py`'s `gen_binop`).
- `13-plus-ticks` — `+` with a `ticks()` call on either side of a `string` converts the call's `int` result like any other `int` operand; the case prints `ok` when the text starts and ends with the literals around it (the number itself is not deterministic).
- `14-trigraph-sequences` — a literal holding `??>`, `??=`, `??(` and the other trigraph sequences prints and measures as the characters written, not as the one character C would read them as.
- `15-str-sub-in-range` — `str_sub(s, i, n)` is the `n` bytes of `s` from byte `i` as a new string: the head, a tail and a single byte of `"hello world"`, each measured with `len`.
- `16-str-sub-empty-and-whole` — an empty span (`n` of 0) answers `""` at `i == len(s)` and past the end, and the whole string is answered as a copy; the span traps are `trap/11-str-sub-past-end` and `trap/12-str-sub-negative-count`.
- A `\0` in a string literal is a compile error (`tests/invalid/nul_in_string.id`): a string never holds a NUL byte, so binary data goes through `stdio_read_mem`, `fs_read_mem` or the store. There is no run-time case here because there is no program to run.
