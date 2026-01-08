# Conditionals

A conditional, or branch, is a control flow statement that determines what actions are taken given a set of preconditions. Currently, there are four conditionals:

- quickreturn
- if
- else
- else if

The quickreturn conditional is a single-line conditional that will immediately return the function with a value if the given condition is met. The if conditional will branch into at most 3 subactions if the given condition is met. The else conditional will likewise branch into at most 3 subactions if the preceding if statement's conditional was not met. The else if conditional is a mixture of the two previous conditional's behaviors, only branching if the preceding if statement's conditional was not met and its own given condition was met.

If a conditional does not have a valid condition statement, that is a compiler error. If a quickreturn conditional has a mismatched return value, that is a compiler error. If a relevant conditional has more than 3 subactions, that is a compiler error. If a conditional is instantiated at nesting depth 4, that is inherently a compiler error (as any subactions would have to be at an unallowed depth level). If an else or else if statement is not preceded by an if or else if statement, that is a compiler error.
