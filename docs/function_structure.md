# Function Structure

An id function is the core building block of an id project. Each id function can return at most one variable, and can take as input at most 4 parameters. Each id function contains at most 3 actions.

## Examples

### Proper Syntax

```id
fn add(x: int, y: int) 
    result = x + y;
return result;

fn process(a: int, b: int, c: int, d: int)
    temp = a + b;
    temp = temp * c;
    print(temp / d);
```

### Improper Syntax

```id
// Error: More than 4 parameters
fn too_many(a: int, b: int, c: int, d: int, e: int)

// Error: More than 3 actions
fn invalid()
    x = 1;
    y = 2;
    z = 3;
    w = 4;  // Too many actions
```
