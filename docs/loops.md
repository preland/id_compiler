# Loops

A loop is a type of action that can be used to repeat a subset of at most 3 actions a given number of times.

There are currently three types of loops:

- foreach
- while
- repeat

A foreach loop repeats itself once "for each" element in a given variable. Each loop iteration is able to reference the given element. A while loop repeats while a given boolean operation is true. No special iterator is accessible. It should be noted that attempting to have an unhalting while loop is a compiler error, as is attempting to artificially create an iterator. Doing so may not always result in a compiler error, as it is challenging to cover every possible situation, but **any code that does so runs the risk of breakage in the future, and as such cannot become standard practice**. A repeat loop repeats a given number of times, with a numeric i iterator given to each loop iteration.

If a loop is not filled with any actions, or is not properly instantiated, that is a compiler error. If a loop contains more than 3 actions, that is a compiler error. If a loop is instantiated at nesting depth 4, that is inherently a compiler error (as any subactions would have to be at an unallowed depth level).

## Examples

### Proper Syntax

```id
// Foreach loop
foreach currentitem in itemcollection
	process(currentitem)
	totalcount = totalcount + 1

// While loop
while value < 10
	value = value + 1
	print(value)

// Repeat loop
repeat 5
	firsttask
	secondtask
	thirdtask
```

### Improper Syntax

```id
// Error: Empty loop
foreach currentitem in itemlist

// Error: More than 3 actions
while condition
	first = 1
	second = 2
	third = 3
	fourth = 4  // Too many

// Error: Potential infinite loop
while true
	action

// Error: Artificial iterator in while
while iterator < 10
	action
	iterator = iterator + 1  // Creating iterator artificially
```
