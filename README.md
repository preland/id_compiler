# `idc` — the `id` toolchain

This is the compiler submodule of [`id_development`](../README.md), the
umbrella repository for the `id` language. It holds the self-hosted compiler
(`compiler/lex`, `compiler/parse`), the `bin/idc` driver, the bootstrap C
(`bootstrap/`), the legacy Python implementation (`idc.py`), the native
backends (`backends/`), the dev tools (`tools/`), and the regression suite
(`tests/`).

For what `id` is, the language rules, and a quick start building
`demos/hello`, see the [umbrella README](../README.md). This file covers what
lives in this directory: the driver's internals, the two code generators, the
native backends, self-hosting, and `idc.py`'s retirement. See
[`../docs/SPEC.md`](../docs/SPEC.md) for the language specification and
[`../docs/HACKING.md`](../docs/HACKING.md) before changing the compiler.

## `bin/idc`: the self-hosted driver, and what it actually does

`bin/idc` is a small bash driver around the self-hosted compiler (`id` itself
has no filesystem/dir-walk/subprocess builtins, so — like every self-hosting
compiler — it needs a bootstrap layer living outside the language; the `fs`
backend below adds *files*, but walking a directory tree is still outside the
language, and walking one is exactly what this driver does). On first
use it builds the two self-hosted stages, `idlex` (lexer) and `idparse`
(parser + C emitter), **from `bootstrap/idlex.c` and `bootstrap/idparse.c` —
the C those two stages emitted about themselves** — and caches them under
`.idc-cache/` (rebuilt automatically if their `id` source changes). `cc` turns
that C back into a compiler, which is then used to rebuild both stages from the
working tree, so nothing but that snapshot is ever frozen and no compiler for
`id` has to exist on the machine beforehand. See
[`bootstrap/README.md`](bootstrap/README.md). From then on, building
`PATH` means: collect its `.id` file(s) (a single file, or every `.id` under a
project directory, sorted by full path — the same order `idc.py` uses), run
`cat files | idlex | idparse` to get C, then hand that C to `cc` — exactly the
pipeline `tools/parity.sh` differentially tests against `idc.py`. `-o`,
`--emit-c`, `--keep-c`, `--cc`, and `--backend DIR` (reading `backend.json` and
linking a native backend, mirroring `idc.py`'s `resolve_backend`) all work the
same as in `idc.py`.

**Coverage:** there is no fallback — `bin/idc` drives the self-hosted stages
and nothing else. They implement the whole language and all of its rules: the
action-per-block limit, nesting depth, 3-functions-per-file, name-type
consistency, export/import access, duplicate names, function-logic uniqueness,
the type checks, and calls that resolve to nothing. Every case in
`tests/invalid/` is checked against **both** compilers and must produce the
same diagnostic, so a message `idc.py` gives and `bin/idc` does not is a test
failure. `bin/idc` also gates on `cc -fsyntax-only` before trusting its own
output; if that ever fires it means a bug in the compiler, and it says so.

The one rule checked in the driver rather than in `id` is the
3-entries-per-directory limit — it is a property of the filesystem, which `id`
cannot see, which is also why the driver exists.

## Two code generators, and one of them optimises

`bin/idc PATH --target llvm` compiles through an SSA intermediate
representation of `id`'s own -- a control-flow graph with phi nodes, a pass
pipeline over it, and an LLVM IR printer at the end -- rather than through a
second walk of the syntax tree. That is what makes optimisation possible at
all, and `-O1` (the default) already removes a third of the emitted IR.

```sh
bin/idc ../demos/calc --target llvm -o calc     # through the IR and its passes
bin/idc ../demos/calc --target llvm -O0         # with every pass off
bin/idc ../demos/calc --target llvm --emit-llvm calc.ll
```

It compiles the compiler, and the compiler it builds reproduces itself exactly.
See [`../docs/LLVM.md`](../docs/LLVM.md).

## Native backends

A **backend** is a directory with a `backend.json` and some native source. It
supplies functions no `.id` file defines; `idc` resolves those calls as
link-time symbols and links the backend's objects into the program. Attach one
with a project's `conf.id` (preferred) or a `--backend DIR` flag.

**Imports are transitive.** An imported directory's own `conf.id` is read too,
so a library can declare the backend it needs and every program that uses it
gets one. Cycles and diamonds terminate — each directory is visited once, keyed
on its resolved path.

| backend | what it adds |
| --- | --- |
| [`backends/fs`](backends/fs) | files: open/read/write/close/size/exists/remove. Needs no system libraries |
| [`backends/gfx`](backends/gfx) | a window and a software framebuffer (X11 / Cocoa) |
| [`backends/gl`](backends/gl) | a hardware-accelerated OpenGL window |

The manifest separates *what* a backend promises from *how* a given compiler
obtains it: `abi` lists the functions in `id`'s own types, and `targets` maps a
code generator (`"c"` today; an LLVM, wasm or interpreter target tomorrow) to
the implementation it should use. Adding a target is a change to the manifest
and the driver that reads it, never to a program's `id` source — see
[`backends/fs/README.md`](backends/fs/README.md), which is written up as the
worked example. `gfx` and `gl` predate `targets` and carry a bare `platforms`
table, which is read as the C target's.

## Self-hosting

The `id`-written compiler (`compiler/lex` lexer + `compiler/parse`
parser/codegen) **compiles its own source** to C that is byte-identical to
`idc.py`, and the self-compiled binary reproduces itself exactly (a fixpoint).
`tests/run.sh` checks both. See `compiler/parse/README.md`. `bin/idc`
is the driver that turns this pair of self-hosted binaries into `id`'s
primary build command — see "`bin/idc`: the self-hosted driver" above.

## The compiler: one implementation, and a bootstrap being retired

**`idc.py` is on its way out, as fast as the work can be done.** It is not a
second supported compiler, not a fallback, and not a place to add anything. The
goal is deleting it. Everything below describes what still holds it here, and
each of those is a task, not a feature —
[`../docs/BACKENDS.md`](../docs/BACKENDS.md) tracks the order.

Until then it is the original, self-contained Python implementation: lexer →
recursive-descent parser → semantic checks (action limit, function-per-file
limit, project entry-count limit, global name uniqueness, function-logic
uniqueness, export/import access, light type checking) → C/LLVM/WASM emission
→ `cc`/`clang`/`wat2wasm`. It **used to be stage 0 of the bootstrap**; that job
went to [`bootstrap/`](bootstrap) — the compiler as C, compiled by `cc` — and
`bin/idc` no longer executes `idc.py` at all. What is left:

1. **The WASM codegen target**, `--target wasm` (and `--emit-wasm`) — the last
   thing `bin/idc` does not have. `--target llvm` moved across and is now the
   self-hosted compiler's own ([`../docs/LLVM.md`](../docs/LLVM.md)); WASM is
   what is left.
2. **Running** a `../docs/TESTS.md` case. `bin/idc --require-tests` counts
   cases; only `idc.py` builds the entry point that executes one.
3. **Being the other side of a differential test.** `tools/parity.sh` and half
   of `tests/` build with both compilers on purpose. That is a use, not a
   dependency: it ends when it is decided that one implementation plus
   `../docs/SPEC.md` is enough.

It is also where the **C runtime prelude** lives, as one string that both
compilers emit verbatim; `tools/gen_runtime_id.py` regenerates the `id`-side
copy from it, so a runtime change is made in one place and parity keeps the two
honest.

**It is not where language features are built**, and a change that grows it is
a change in the wrong direction. "Reference implementation" is what this
section used to call it, and that reading — *the definition of correct, so
define the feature here and port it* — is why work kept landing in Python
instead of in `id`. Stage 0 needs a construct only once the self-hosted
compiler's own source uses that construct — and since `bootstrap/` landed,
"stage 0" means the checked-in C rather than the Python, so teaching the
language a construct is `tools/regen_bootstrap.sh` and not a second
implementation. Read
[`../docs/HACKING.md`](../docs/HACKING.md) before changing the language;
[`compiler/parse/MAP.md`](compiler/parse/MAP.md) is the index
that makes the self-hosted tree navigable, which was the other half of the
problem.

**`bin/idc`** (see the umbrella [Quick start](../README.md#quick-start)) is
the **primary** way to build a program: it drives the self-hosted
`idlex`/`idparse` pair and does not fall back. It enforces every rule of the
language, and its diagnostics are checked against `idc.py`'s, case by case, by
`tests/invalid.sh`.

Generated code details (true of both implementations — the self-hosted
emitter mirrors these byte-for-byte where it's implemented at all):

- `id` functions are prefixed `id_` in C (so `id` `main` becomes `id_main`,
  wrapped by a real C `main`). Exported variables become C globals.
- A project without a `main` compiles to a `.o` object file (e.g. a library
  like `../demos/engine`).
- String concatenation allocates and never frees; fine for now, a real
  runtime would need ownership rules or GC.
