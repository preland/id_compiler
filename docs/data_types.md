# Data Types

This document should answer the following questions:

- What are the primitive data types supported in id (e.g., int, string, float, bool)?
- What are the sizes, ranges, and behaviors of each primitive type?
- What are composite types (e.g., arrays, objects) and how are they defined?
- What are "stem types" and how do they differ from explicit types?
- How does type inference work, if at all?
- What type conversions are allowed and how are they performed?
- What operations are supported on each type (e.g., arithmetic, comparison)?
- Are there any type-related compiler errors or warnings?

The data types supported by id by default are the typical C ones. They are implemented through code as either base or standard features. The "stem" type is a special type, which can be interpreted into any given type. As this is a potentially unstable type that should not be used in typical code, this type is hidden behind a flag. Using stems without properly defining type during its actual usage is a compiler error. In general, id is a strongly typed language, with no type inference. Type conversions must be done with functions. "Generic" operation types (arithmetic, comparsion, etc.) can only be done on types where that behavior has been defined.