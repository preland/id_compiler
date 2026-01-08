# Conditionals

A conditional, or branch, is a control flow statement that determines what actions are taken given a set of preconditions. Currently, there are four conditionals:

- quickreturn
- if
- else
- else if

The quickreturn conditional is a single-line conditional that will immediately return the function with a value if the given condition is met. The if conditional will branch into at most 3 subactions if the given condition is met. The else conditional will likewise branch into at most 3 subactions if the preceding if statement's conditional was not met. The else if conditional is a mixture of the two previous conditional's behaviors, only branching if the preceding if statement's conditional was not met and its own given condition was met.

If a conditional does not have a valid condition statement, that is a compiler error. If a quickreturn conditional has a mismatched return value, that is a compiler error. If a relevant conditional has more than 3 subactions, that is a compiler error. If a conditional is instantiated at nesting depth 4, that is inherently a compiler error (as any subactions would have to be at an unallowed depth level). If an else or else if statement is not preceded by an if or else if statement, that is a compiler error.

## Examples

### Proper Syntax

```id
// Quickreturn conditional
quickreturn true if number > 10

// If conditional with up to 3 actions
if number == 5
	counter = counter + 1
	print("Equal to 5")
	multiplier = multiplier * 2

// If-else structure
if isvalid
	firstaction
	secondaction
else
	thirdaction

// If-else if-else chain
if firstvalue > secondvalue
	outcome = "a greater"
else if firstvalue < secondvalue
	outcome = "b greater"
else
	outcome = "equal"
```

### Improper Syntax

```id
// Error: No condition
if
	action

// Error: More than 3 actions in if
if number == 1
	first = 1
	second = 2
	third = 3
	fourth = 4  // Too many actions

// Error: Else without preceding if
else
	action

// Error: Quickreturn with mismatched return type (assuming function returns int)
quickreturn "string" if isvalid  // If function expects int

// Error: Nesting depth 4 (assuming outer contexts)
if outer // 2 (fn declaration would be depth 1)
	if inner1 // 3 
		if inner2 // 4; too deep
			if inner3  // conditionals at depth 4 cannot have valid submembers, making them impossible
				action
```
