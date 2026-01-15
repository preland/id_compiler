# Flags

This document should answer the following questions:

- What are flags in id and how are they used?
- What is the syntax for declaring flags in a file?
- What flags are available (e.g., #stem_types, #debug, #asmfn, #allowasm) and what do they do?
- How do flags affect compilation or runtime behavior?
- Can flags be combined, and are there interactions between them?
- What happens if an invalid or misplaced flag is used?
- Are flags file-scoped or project-wide?
- How are flags validated by the compiler?

Flags are special file-wide modifiers that allow for behavior that is otherwise not allowed in id. They are used with the syntax `#flagname`. Each flag must be declared at the top of the file, each on its own line. Flags should be used minimally, and features requiring the usage of flags should be wrapped so that flag usage does not expand unnecesarily. Declaring a flag but failing to use any features of the flag is a compiler error. Flags are required to, among other things, enable stem type usage, enable assembly function usage, create assembly functions, disable specific portions of syntax validation (should only be used to test and prototype, and should not be present in deployed or non-temporary code), and to enable certain debug features.