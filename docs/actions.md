# Actions

Actions are the individual lines of code within an id function. An action is one of the following:

- A loop/conditional
- A variable assignment or modification
- An execution of a function

Each type of action has specific rules and stipulations. If these rules are not followed exactly, that is a compiler error.

## Examples

### Proper Syntax

```id
// Variable assignment
value = 5

// Variable modification
counter = counter + 1

// Function execution
print("Hello")

// Loop
foreach currentitem in itemlist
	process(currentitem)

// Conditional
if value > 0
	result = true
```

### Improper Syntax

```id
// Error: Invalid action type
random_statement

// Error: Malformed assignment
value =   // Incomplete

// Error: Undefined function call
undefined_function()

// Error: Loop with invalid syntax
foreach   // Missing variable
	action
```
