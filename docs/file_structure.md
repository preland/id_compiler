# File Structure

Each file in id has at most 3 functions or a single object declaration with no functions. If it has more than this allotment, that is a compiler error. A file may also have a flag command on its first line and on consecutive lines in the case of multiple flags. If a flag is invalid, or is misplaced within the file, that is a compiler error.

## Examples

### Proper Syntax

```id
// File with flags and functions
#stem_types
#debug

func calculate(x: int, y: int) -> int {
    return x + y;
}

func display(result: int) {
    print(result);
}
```

```id
// File with single object
object Calculator {
    value: int;
    init(value: int);
    add(amount: int) -> int;
}
```

### Improper Syntax

```id
// Error: More than 3 functions
func func1() {}
func func2() {}
func func3() {}
func func4() {}  // Too many
```

```id
// Error: Misplaced flag
func test() {}
#invalid  // Flag after function
```

```id
// Error: Object with functions (should be separate file)
object Test {
    func method() {<impl>}  // Not allowed in object file
}
```
