# Stage 0: the compiler, as C

`idlex.c` and `idparse.c` are the C that `compiler/lex` and `compiler/parse`
emitted about themselves. `cc` turns them back into a working `id` compiler,
which is what lets a fresh checkout build `id` without a compiler for `id`
already being on the machine — and therefore what lets `idc.py` go.

They are not a second implementation. They are the *same* implementation,
frozen at the commit that regenerated them, in the one language every machine
can already compile.

## The chain

`bin/idc` runs it on a cold cache, into `.idc-cache/`:

```
bootstrap/idlex.c   --cc-->  idlex0  \
                                      +--> compiler/{lex,parse} --> idlex, idparse
bootstrap/idparse.c --cc-->  idparse0/
```

Stage 0 is the snapshot; **stage 1 is what every later build actually runs**,
and it is compiled from the working tree. So a change to the compiler takes
effect on the next build without anything here being touched. Stage 0 is only
consulted when it is missing, or when `cc` has not yet been run on the C.

## When this has to be regenerated

Only when stage 0 can no longer compile the working tree — which is exactly
when the compiler learns a **new construct that the compiler's own source then
uses**. That is the two-commit rule, and it is the reason this directory
exists:

1. Teach the compiler the construct, without using it. Run
   `tools/regen_bootstrap.sh`, which makes stage 0 a compiler that knows it.
2. Use the construct in `compiler/`, `idstd` or anywhere else.

`docs/RELIANCES.md` §1 is the argument: every additive language feature —
`break`, a record, a binary literal — was blocked on `idc.py` having to compile
those trees while being frozen. The blocking thing is now a snapshot that can
be moved forward in one command.

Regenerating for any other reason is allowed and cheap, but it is churn: the
diff is the whole file.

```sh
tools/regen_bootstrap.sh          # rewrite both files from the working tree
tools/regen_bootstrap.sh --check  # fail if they are not what the tree emits
```

## What is guaranteed about these files

* **They are deterministic.** The same source emits the same bytes, so a diff
  here is a real change in the compiler and never noise.
* **They compile clean** at `cc -std=c11 -O2`, with no warnings and no flags
  beyond that. They need no headers, no library and no other file in this
  repository — the runtime prelude is emitted into the top of each one.
* **They are stage 0 only.** Nothing links against them, nothing includes them,
  and no program in this repository is built from them. Editing them by hand is
  meaningless: the next `tools/regen_bootstrap.sh` overwrites the edit, and
  `--check` fails until it does.
