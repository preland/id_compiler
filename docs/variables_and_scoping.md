# Variables and Scoping

This document should answer the following questions:

- How are variables declared in id (e.g., syntax, keywords)?
- What is the difference between variable declaration and assignment?
- What are the scoping rules (e.g., local, global, object-level)?
- How are variable lifetimes managed (e.g., when are they created/destroyed)?
- Is mutability supported, and how is it controlled?
- How are variables accessed and modified within different scopes?
- What are the rules for variable naming and shadowing?
- Are there any restrictions on variable usage (e.g., in loops, conditionals)?

Variables are declared with the syntax `(export|import (order <n>)) (mut) <type> name (= <assignment>);`, with the assignment optional. If an assignment is not explicitly made, the variable is still given an implicit assignment (usually nil, or the original assignment if imported), so assigning a variable on declaration is good practice. After a variable declaration, the variable can be reassigned with the syntax `name = <assignment>` if it is mutable. Variables are by default immutable. Variables are also by default local. A variable can be made accessible in other functions through the usage of the `export` keyword. The variable can then be accessed in another function using the `import` keyword. The order of access for exported/imported variables is strict: the initial declaration is the first to read/write to the variable by default. If the variable is only imported once, then the order keyword is optional. If it is imported more than once, the read/write order must be explicitly stated using the `order <n>` syntax. For simplicity and sanity's sake, import/export can only be used function to function, and not to escape the scope of a loop or conditional within a function.
