# Structs

`struct Name { T a; T b; }` in a file of its own: reference semantics, three
fields at most, constructors as initialisers, fields read and written with
`.`, and struct literals in test cases (docs/SPEC.md, structs). Each case is a
directory, because a struct's file holds nothing else. Runs on C and LLVM.
