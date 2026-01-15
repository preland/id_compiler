# Built-in Elements

This document should answer the following questions:

- What built-in functions are available in id (e.g., print, math operations)?
- What is the syntax and signature for each built-in function?
- How are built-in functions categorized (e.g., I/O, math, string manipulation)?
- Are built-ins overloaded or polymorphic?
- How do built-ins interact with user-defined functions?
- What are the return types and side effects of built-ins?
- Are there any restrictions on using built-ins (e.g., in assembly functions)?
- How are built-ins implemented (e.g., via LLVM intrinsics)?

"Built-in" functions, classes, and variables are classified into three classes:

## Base

Base features exist entirely within the compiler, and are not literally expressed in code that could be reasonably utilized elsewhere. The number of these features will change, as these should be as minimal as possible to preserve modularity.

## Standard

Standard features are the "standard library" of id. These include generic variables and functions that can be reasonably assumed to be generally utilized. These are expressed literally through id code. Extended features may become standardized if they see wide usage.

## Extended

Extended features exist in order to prevent "feature collision" between different libraries. Due to the simplicity and harshness of constraints, as well as the novelty of this coding philosophy, it is entirely possible for two different libraries to independently create the same feature, which would result in a duplicate feature error. Any such feature collision **must** be reported rapidly so that the function can be added to the extended library to prevent future collisions. Extended features are not guaranteed to be useable or safe in all cases, and should usually only be used incidentally when another project collides with the extended feature. If an extended feature sees common and intentional usage, it should become a standardized feature.

## Non-exhaustive list of base and standard features

This is a very non-exhaustive list of features; features will be added as they are needed. All of these features, as with all id code, can be decomposed into LLVM IR.

### Standard features

#### variables/classes

- int
- char
- string
- float

#### functions

- print


