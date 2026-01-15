# Runtime Behavior

This document should answer the following questions:

- How are objects instantiated and managed at runtime?
- What is the memory model (e.g., stack vs. heap, garbage collection)?
- How are variables and objects allocated and deallocated?
- What is the execution model (e.g., interpreted, compiled to machine code)?
- How are function calls and returns handled?
- What concurrency features exist (e.g., threads, async)?
- How are I/O operations performed?
- What are the performance characteristics and optimizations?

The runtime behavior is not something that I am entirely certain of currently. I know that I want this language to be mainly a compiled language, though using an interpreter for small incremental changes during development may be a consideration in the future after a self-hosted stable compiler is created. The memory model should be similar to that of Rust's borrow checker, where memory allocation and deallocation occurs according to variable scope. Concurrency features is something that I am unsure of how they should be handled. I think that I want to have it so that threading occurs automatically so that the end user doesn't have to handle it, but I'm not sure? I/O operations should behave the same as other parts of id, where it can be compiled directly down. The performance of id code should be similar to that of Rust or C/C++. As all id code can be directly decomposed into LLVM IR, the main optimization methods would be direct optimization of low-level assembly functions and/or higher level function optimizations, as well as determining the exact method of decomposition (optimized for size by having all functions individually expressed and then linked to each other vs optimized for speed by having all functions inlined at the compiler; the level at which inlining occurs could also be adjusted granually).
