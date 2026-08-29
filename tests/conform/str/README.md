# `string` conformance cases

Each case pins down one semantic question about `id`'s `string`. Build and
run with `IDC_NO_STD=1 bin/idc tests/conform/str/NN-name.id -o /tmp/cf_out &&
/tmp/cf_out`; stdout must match `NN-name.expected` byte for byte, and every
case here exits 0 (no `.exit` file).

- `01-concat` — `+` between two strings concatenates them.
- `02-plus-int-both-sides` — `+` with an `int` operand on either side of a `string` converts the `int` and concatenates (`"lucky " + 7` and `7 + " lucky"` both work).
- `03-plus-float` — `+` with a `float` operand converts it via the same `%g` formatting `print` uses (`"pi is " + 3.5` → `"pi is 3.5"`).
- `04-len-empty-and-nonempty` — `len("")` is `0` and `len("hello")` is `5`; empty and non-empty strings both measure correctly.
- `05-charat-in-range-and-zero` — `charat` at index `0` and at a middle index return the byte's ASCII code (`'h'` → `104`, `'l'` → `108`), not the character itself.
- `06-charat-past-end-and-negative` — `charat` past the end of the string (index `5` on a 2-byte string) and at a negative index (`0 - 1`) both return `-1` rather than trapping.
- `07-chr-roundtrip` — `chr(65)` builds `"A"`, and `charat` on that string recovers `65`: `chr`/`charat` round-trip.
- `08-to-int-numeric` — `to_int` parses an ordinary positive number (`"42"` → `42`) and a negative one (`"-7"` → `-7`).
- `09-to-int-non-numeric` — `to_int` on a non-numeric string (`"banana"`) and on `""` both give `0` (it's `atoi` underneath: no error, just `0` on anything with no leading digits).
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
