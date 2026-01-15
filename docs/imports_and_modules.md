# Imports and Modules

This document should answer the following questions:

- How does the module system work in id?
- What is the syntax for importing functions, objects, or variables from other files?
- How are exports defined (e.g., are all public by default)?
- How does module resolution work (e.g., based on directories, file paths)?
- What are the rules for circular imports or dependencies?
- How are imported items accessed in code?
- What happens if an import fails (e.g., missing file, undefined symbol)?
- Are there any restrictions on imports (e.g., in assembly files)?

Functions and objects are globally declared, and can be accessed as such. There is no explicit module importing/exporting (ie #include in C/C++). If a function or object is used without existing, that is a compiler error.