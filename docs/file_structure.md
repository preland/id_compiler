# File Structure

Each file in id has at most 3 functions or a single object declaration with no functions. If it has more than this allotment, that is a compiler error. A file may also have a flag command on its first line and on consecutive lines in the case of multiple flags. If a flag is invalid, or is misplaced within the file, that is a compiler error.

## Examples

### Proper Syntax

```id
// File with flags and functions
#stem_types
#debug

fn calculate(firstnumber: int, secondnumber: int)
    int ret = firstnumber + secondnumber    
return int ret

fn display(outcome: int)
    print(outcome)
return nil
```

```id
// File with single object
object Calculator {
    storedvalue: int;
    init(storedvalue: int);
    add(amount: int) -> int;
}
```

### Improper Syntax

```id
// Error: More than 3 functions
fn function1()
fn function2()
fn function3()
fn function4()  // Too many
```

```id
// Error: Misplaced flag
fn testfunction()
#invalid  // Flag after function
```

```id
// Error: Object with functions (should be separate file)
object TestObject {
    fn method()  // Not allowed in object file
```
    func method() {<impl>}  // Not allowed in object file
}
```
