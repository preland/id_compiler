# Function Structure

An id function is the core building block of an id project. Each id function can return at most one variable, and can take as input at most 4 parameters. Each id function contains at most 3 actions. An id function always ends with a return statement at depth 1, the same as the function declaration.

## Examples

### Proper Syntax

```id
fn add(firstnumber: int, secondnumber: int)
    sumresult = firstnumber + secondnumber
return int sumresult

fn process(firstvalue: int, secondvalue: int, thirdvalue: int, fourthvalue: int)
    temporary = firstvalue + secondvalue
    temporary = temporary * thirdvalue
    print(temporary / fourthvalue)
return nil
```

### Improper Syntax

```id
// Error: More than 4 parameters
fn too_many_parameters(first: int, second: int, third: int, fourth: int, fifth: int)

// Error: More than 3 actions
fn invalid_function()
    firstvar = 1
    secondvar = 2
    thirdvar = 3
    fourthvar = 4  // Too many actions
```
