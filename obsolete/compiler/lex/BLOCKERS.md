# idc-in-id: status and blockers

The goal is to reimplement `idc.py` (lexer → parser → semantic checks → C
emission) in the `id` language itself. This directory contains **stage 1, the
lexer**, which works: it reads id source on stdin and prints a normalized token
stream, and it can tokenize its own source.

Each stage has driven language features into `idc.py`. The lexer is built; the
parser blockers are now cleared (growable lists + `to_int`); the parser and C
emitter remain to be written. This file records what each stage needed.

## Features added for the lexer

- **`while` loops** — there was no iteration at all. A lexer must scan a string
  of unknown length. (Recursion technically works, but the 3-action limit makes
  a recursive scanner unwritable.)
- **`len(s)`** — string length.
- **`charat(s, i)`** — the byte code at index `i` (or `-1` past the end). The
  language could not look inside a string before this.
- **`chr(n)`** — a one-character string from a byte code, for rebuilding lexemes
  and output.
- **`read_all()`** — slurp all of stdin into one string. `input()` reads a
  single line and returns `""` on EOF, which is indistinguishable from a blank
  line — useless for reading multi-line source. `read_all()` sidesteps that.

## Features added for the parser

- **Growable lists with reference semantics.** `T[]` became a heap list:
  `push`, `xs[i] = v`, empty `[]`, `len`, and mutation visible across calls.
- **`to_int(s)`** — parse a string to an int.

## Parser blockers (RESOLVED via growable lists + to_int)

The six capabilities below were each missing. Rather than add structs, maps,
tuples, and references separately, one feature subsumes all of them: a **growable
list with reference semantics** (`T[]` is now a heap object you can `push` to,
index-assign into, and mutate through a shared reference). Plus `to_int`.

1. **AST / record types.** Instead of node structs, an AST is a handful of
   *parallel lists* indexed by an integer node id: `kind[id]`, `text[id]`,
   `child_a[id]`, ... `addnode(...)` pushes one cell to each and returns the new
   id. (Demonstrated working.) No named-field type needed.

2. **Growable token buffer + element assignment.** `push(xs, v)` appends;
   `xs[i] = v` writes; `[]` makes an empty typed list. Done.

3. **Keyed maps / symbol tables.** Built in `id` as two parallel lists (keys,
   values) with linear lookup — fine at compiler scale. No builtin map needed.

4. **Multiple returns.** A parse routine returns its node id (an `int`) and
   advances the shared cursor as a side effect — return-plus-mutation covers the
   "(node, next position)" pair.

5. **Mutable shared state.** A list is a reference: pass the token list and a
   one-element cursor cell to a function and it mutates them in place. This is
   the cursor-threading mechanism recursive descent needs.

6. **`string` → `int`.** `to_int(s)` added.

## Intentional constraints (not blockers -- the lexer complies with them)

These are deliberate design choices, and the lexer is written to honor them:

- **3 actions per block** + **maximum nesting depth of 2.** Every block (the
  function body and each branch/loop body) gets its own 3-action budget, and
  blocks may nest only two deep. This is why dispatch is a *chain* of one-
  decision functions (`scan_one -> scan_word -> scan_token -> ...`) instead of a
  pyramid of nested `if`/`else`. It forces small, shallow, named functions.
- **3 functions per file.** The 20-function lexer spans 7 files. Expected; the
  language grows programs by adding files.

## Variable naming (resolved)

The old program-wide unique-name rule forced hand-mangling (`src_a`, `src_b`,
...). It has been replaced by **type-consistency**: a name may recur across
functions as long as it always has the same type, so the dispatch chain now
just uses `src`/`i`/`ni` everywhere. Exported names stay reserved globally. The
intent (a name never means two different things) is preserved; the incidental
restriction (no two functions may share `i`) is gone.

## Other notes

- **No character literals or `char` type.** Character work is done with magic
  byte codes (`34` = `"`, `47` = `/`, `10` = newline). Workable, error-prone.

## Status

Stage 1 (lexer) is built, the parser blockers are cleared, and **stage 2 (a
recursive-descent parser) is demonstrated** in two demos that read the token
stream into an AST held in parallel lists, threading a shared cursor:

- `demos/idc_in_id_calc` — arithmetic expressions, evaluated and printed.
- `compiler/parse` — `id` **functions and statements** (params, types,
  declarations, assignments, `if`/`else`, `while`, calls, expressions), and
  **stage 3: C emission** from that AST. The emitted C is compiled by `cc` and
  run, so the whole front+middle (lex → parse → emit C) is written in `id`.

Remaining toward a fully self-hosting `idc`: the fuller expression grammar
(indexing, array literals, `import`) and a type pass (for `print` and string
concatenation in emission). Float literals are now lexed, parsed, and emitted
byte-identically to idc.py (see chars/numlit/ here and the float leaf in
compiler/parse), closing the self-hosting compiler's last known gap
(tools/parity.sh demos/hello now MATCHes).
