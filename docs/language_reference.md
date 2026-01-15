# Language Reference

This document should answer the following questions:

- What is the formal grammar or syntax for id (e.g., EBNF)?
- How is indentation and whitespace handled?
- What are the rules for identifiers, literals, and operators?
- How is nesting depth calculated and enforced?
- What are the precedence and associativity rules for operators?
- How are comments defined and used?
- What are the lexical rules (e.g., tokens, keywords)?
- How does the parser handle ambiguities?

The overall grammar of syntax takes inspiration mainly from C++ and Python, with some minor influences from Rust. The core philosophy is to reduce boilerplate and maximize visual clarity at a glance, while minimizing how much is "going on" in any given screen. The syntax should be challenging but familiar to those who have used other programming languages before, and should be relatively simple for a new coder to understand (though it may seem overly restrictive to write at first). After some experience of reading and writing id, it should be easy to see when code is not following the rules of the language, and more importantly, it should be relatively trivial to quickly look at code and understand what it does at a high level. One of the main goals of id is to prevent developers from hiding the behavior of their code through subterfugal tactics typically enabled (or in some cases, outright encouraged) by the looseness of other languages.

Variable, function, and class names should be simple but direct in what they are doing. Code review should simply boil down to recursively answering "Does this function, variable, or class behave appropriately to what its name implies?". While function and class names are implicitly unique across a project, good code should not ever attempt to "work around" this intentional design choice by making minor changes to the function name that do not change its actual meaning. If you ever believe that two functions or classes should have the same name, first determine what the difference between the two is. That difference is what you should use to deliniate between their names. If you determine that they functionally do the same thing, **then one of them should not exist**.

Code comments are allowed using the `//` prefix borrowed from C/C++, but code comments should not be common practice. The code should be self-documenting in nature; there should be little to no need to write code comments to explain what the code does. If you feel the need to do so, you either are falling back on habits from other languages where this style of commenting is more warranted, or are not properly writing the code.

Code review is an in-built feature of id, accessible by running `id --code-review <username>`. In this mode, it will present you with a function or class in the directory, and will ask you if the feature behaves appropriately to what its name implies. Code review starts at the lowest level, and no function or class will be presented before you have personally reviewed every single dependent function. If a function or class has been changed, it's code review is nullified until it is performed again. This means that when you read a function or class in this mode, you can be certain that everything expressed behaves exactly how its name implies it should behave. While this is currently disabled, it is strongly suggested to alias `id` to `id --require-code-review <username>` to ensure that this code review becomes a part of your routine.

"id" is an acronym, short for Inherently Determinable. This means that any code written in id should be clearly understandable, without any need for external explanations which could be incorrect or misleading, or the need to make unfounded assumptions about code you have never seen.