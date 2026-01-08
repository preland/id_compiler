# Loops

A loop is a type of action that can be used to repeat a subset of at most 3 actions a given number of times.

There are currently three types of loops:

- foreach
- while
- repeat

A foreach loop repeats itself once "for each" element in a given variable. Each loop iteration is able to reference the given element. A while loop repeats while a given boolean operation is true. No special iterator is accessible. It should be noted that attempting to have an unhalting while loop is a compiler error, as is attempting to artificially create an iterator. Doing so may not always result in a compiler error, as it is challenging to cover every possible situation, but **any code that does so runs the risk of breakage in the future, and as such cannot become standard practice**. A repeat loop repeats a given number of times, with a numeric i iterator given to each loop iteration.

If a loop is not filled with any actions, or is not properly instantiated, that is a compiler error. If a loop contains more than 3 actions, that is a compiler error. If a loop is instantiated at nesting depth 4, that is inherently a compiler error (as any subactions would have to be at an unallowed depth level).
