# Assembly

The id compiler is capable of low level "assembler" output via llvm. All aspects of id can be broken down into these granular "building blocks". The way that these building blocks are implemented is through a special assembly function type.

These functions, declared and implemented with the asmfn keyword, have the same 3 "actions" limitations, with the actions allowed being only one of the following:
- A valid llvm IR instruction
- a call to another assembly function

These functions can only be declared in a file with only other assembly functions, with the flag `#asmfn` present. An assembly function can be used by a normal function so long as the `#allowasm` flag is present in the normal function's file.