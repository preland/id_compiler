# idc-in-id, stages 2b + 3: an id parser and C emitter, written in id

Parses `id` source into an AST and **emits C** from it — the front and middle of
`idc`, written in `id` itself. Fed by the stage-1 lexer through a pipe; the AST
is built entirely in parallel lists (no structs). Pass `ast` to dump the parsed
structure instead of emitting C.

```sh
../bin/idc compiler/lex      -o idlex
../bin/idc compiler/parse -o idparse

# emit C, then compile and run it -- the whole front+middle is written in id:
printf 'square(int n) { int r = n * n; } return int r;\nmain(int argc, string[] argv) { int a = square(6); } return int a;\n' \
  | ./idlex | ./idparse > out.c
cc out.c -o out && ./out; echo $?      # 36

# or inspect the AST:
printf 'add(int x, int y) {\n  int sum = x + y;\n} return int sum;\n' | ./idlex | ./idparse ast
# (func add (params (param int x) (param int y)) int (body (decl int sum (+ x y))) (return sum))
```

## What it handles

- **Functions:** `name(params) { body } return TYPE expr;` (and `return void;`),
  with typed parameters and `T[]` types.
- **Statements:** declarations (`[export] type name = expr;`), assignments
  (`name = expr;`), `if`/`else`, `while`, and expression statements (calls).
- **Expressions:** integer/string literals, variables, function calls with
  arguments, parentheses, and left-associative binary operators across the full
  precedence ladder — `||`, `&&`, relational/equality (`== != < > <= >=`, and a
  bare `=` meaning equality), then the bitwise group `|`, `^`, `&`, `<< >>`,
  then additive (`+ -`) and multiplicative (`* / %`), then unary (`- ! ~`).
  As in `idc.py`, the bitwise levels sit *below* the comparisons — tighter, not
  looser. Because that is the opposite of C, a comparison with an
  unparenthesized bitwise operand is a compile error here (`idc.py` accepts it);
  write `(flags & MASK) != 0`.
- **Systems types:** the 64-bit `word`, integer literals wider than an `int`
  (emitted with C's `LL` suffix), the flat-store builtins (`alloc`,
  `store_size`, `peek8/16/32/64`, `poke8/16/32/64`), the unsigned operations
  (`udiv`, `umod`, `ult`, `ushr`), and the store/string bridges (`str_of_mem`,
  `mem_of_str`).

The `classify` and `countdown` shapes from the other demos parse exactly.

## How it is built (the ABI)

Same techniques as the calculator, scaled up:

- **Shared state in exported lists**, reached via `import`: the token store
  (`tkind`/`ttext`) and the AST store. Parse routines take no state parameters;
  only the cursor `pos` (a one-element `int[]` cell) is threaded by reference.
- **Nodes are seven parallel lists** — `nkind`, two int fields, two string
  fields, and **two child-list fields** (`nl1`/`nl2` are `int[][]`) so a node can
  hold variable-arity children: a function's params and body, an `if`'s two
  branches, a call's arguments. Two more columns record where a node came from
  rather than what it is: `nline` (its source line) and `nunit` (its
  compilation unit, which is what keeps a name's type per-unit).
- **Recursive descent** with the now-familiar split: every loop body that folds
  operators or collects list items is its own small function, to respect the
  3-action-per-block and 2-deep-nesting limits.

## C emission (stage 3, the `gen*.id` files)

The emitter walks the AST and prints C, mirroring `idc.py`: id functions become
`id_NAME`; locals are **hoisted** to the top of their C function (id is
function-scoped, so a var declared inside a branch and used after it must be
declared at function scope) and their initializers become assignments; forward
declarations precede definitions; a C `main()` wraps id's `main`. id's bare `=`
equality becomes C `==`. Verified end to end: emitted C is compiled by `cc` and
run (`square(6)` exits 36, `sumto(5)` exits 15).

## Emission, type-dependent

A type pass (built on id's one-type-per-name rule, so a single global symbol
table suffices) drives type-dependent emission:

- `print(int)` → `id_print(id_str_of_int(x))`; string `+` → `id_concat(...)`
  with operands coerced; string `==`/`!=`/`=` → `(strcmp(a, b) OP 0)`
- `(import name)` reads the exported global; exported vars become C globals in an
  `/* exported variables */` block (not hoisted locals)
- list types (`T[]`) map to `IdList*`; `main(int, string[])` gets the argv-
  marshalling wrapper
- `||`/`&&` (above equality), unary `-`/`!`/`~`, array indexing `a[i]` and
  index-assignment `a[i] = v`, array literals (`[]`, `[a, b]`), and the list
  builtins — `push` → `id_list_push` and `len` → `id_list_len`/`id_len` — all
  emit with the boxing/unboxing casts the uniform cells need
- `word` is C `long long`; `print(word)` → `id_str_of_word(x)`. Arithmetic and
  bitwise operators widen their operands (`int` < `word` < `float`), and the
  result type is what decides the shape: `a << b` and `a >> b` always become
  `id_shl`/`id_sar`, while `/` and `%` become `id_sdiv`/`id_smod` **only** on a
  `word` — plain `int` division keeps emitting `(a / b)`, so nothing that
  compiled before changes. `& | ^` are plain C infix
- the systems builtins emit as their C helper applied to arguments cast to
  `(long long)` — `alloc` → `id_mem_alloc`, `store_size` → `id_mem_size`, and
  `id_` + the name for the rest. `mem_of_str` takes a string, so it is the one
  that emits with no cast

`idc.py` is frozen (`../docs/HACKING.md`) and no longer built against here for
comparison; correctness is checked by running the emitted C
(`tests/self_host_build.sh`, `tests/conform.sh`) rather than by diffing it
against a second implementation.

## Self-hosting

The compiler **compiles itself**: `idlex | idparse` over its own source —
both the stage-1 lexer (`compiler/lex`) and this parser/codegen
(`compiler/parse`) — and the result is a **fixpoint**: compiling the compiler
with itself and using that binary to recompile the compiler's source produces
C identical to its own, so the self-compiled compiler reproduces itself
exactly. The test suite checks the fixpoint (`tests/run.sh`, "self-hosting
fixpoint").

The lexer change that unblocked this was backslash-escape handling in string
literals (so a `\"` no longer ends a string early); the runtime prelude that
`idparse` prints is one such string. Float literals remain the one unimplemented
piece of the language (the lexer still splits `0.8` into `0 . 8`), but the
compiler's own source uses no floats, so self-hosting does not need them.
