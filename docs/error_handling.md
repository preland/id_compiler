# Error Handling

This document should answer the following questions:

- How are compile-time errors reported and what are common causes?
- How are runtime errors handled (e.g., exceptions, panics)?
- What error handling mechanisms exist (e.g., try/catch, assertions)?
- How are errors propagated and caught?
- What debugging features are available (e.g., via #debug flag)?
- How are linker errors resolved?
- What are the differences between compiler errors, warnings, and runtime errors?
- How can users handle or recover from errors?

Compiler errors are thrown at compilation. Runtime errors are discouraged, but can be thrown using the `throw <cause>` syntax, which must be enabled using the `#allowthrow` flag. Outside of the aforementioned throw keyword, runtime errors should not be possible. The `#debug` flag enables verbose logging within its scope, which should record the exact throw that occurred, as well as a trace that includes the variable/parameter values of the functions in the trace. If one intends to generate these traces intentionally, the `halt` keyword should be used instead of the throw keyword (NOTE: halt does not contribute to the action count of a function). Halt pauses execution and prints the relevant trace, and execution can then be resumed afterwards, allowing for the statements to be chained together. If a `#nodebug` flag is present at a higher scope than a `#debug` flag, then the debug flag is overriden, and vice versa.

It should be noted that there are no compiler warnings. This is an intentional feature, as id's main purpose is to strictly ensure that code is in as simple a state as possible. Bad code formatting and style is considered just as bad as blatantly illegal syntax.
