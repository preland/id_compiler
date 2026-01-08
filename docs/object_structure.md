# Object Structure

An id object is used to wrap variables and objects into more unified semantic wrappers and variables. An id object can have an unlimited number of subvariables and subfunctions. Subvariables must have an explicit type (or can use the stem type if enabled via flag), and subfunctions must be declared with an explicit type like subvariables, with the main exception being that they can have an explicit "void" type.

As with functions, an object can access any existing variable types within the scope of the project, and can import variables for initializing subvariables. The only function implementation allowed is that of the initialization, with all subfunctions declared required to be implemented somewhere in the project. Notably, two objects can share the same subfunction. Otherwise, objects must be pragmatically unique. If an object does not have any variables, or only has one variable, that is a compiler error. If a subvariable does not have a valid explicit type, that is a compiler error. If a subfunction does not have a valid explicit type, that is a compiler error. If the initialization function attempts to access variables without importing them, or attempts to import variables not exported, that is a compiler error. If the initialization function is invalid, that is a compiler error. If there are other function implementations in the same file as the object declaration, that is a compiler error. If a subfunction does not exist within the root directory of compilation, that will result in a linker error unless otherwise rectified.

## Examples

### Proper Syntax

```id
object Person {
    name: string;
    age: int;
    salary: float;
    
    init(name: string, age: int);
    get_name() -> string;
    set_age(new_age: int) -> void;
    calculate_bonus() -> float;
}
```

### Improper Syntax

```id
// Error: Only one variable
object Single {
    value: int;
}

// Error: No explicit type for subvariable
object Bad {
    name;  // Missing type
    age: int;
}

// Error: Subfunction without type
object Invalid {
    name: string;
    age: int;
    get_name();  // Missing return type
}

// Error: Function implementation in object file
object Wrong {
    name: string;
    
    func get_name(name: string)  // Implementation not allowed
        name = "hi"
    return string name
}
```
