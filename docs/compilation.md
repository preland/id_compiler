# Compiling an id project

To compile an id project, you can simply run `id <root_directory>` in your terminal of choice, or simply run `id` if you have navigated to your desired root directory. If there is a main function within the root directory, it will compile to a binary; otherwise it will compile to a library. You can use this feature to compile subdirectories of a binary into their own libraries, though it should be noted that the libraries will fail to link if they reference functions present outside of the relevant subdirectory.

## Examples

### Proper Syntax

```bash
# Compile from root directory
id

# Compile specific directory
id /path/to/project

# Compile subdirectory to library
id subproject
```

### Improper Syntax

```bash
# Error: Invalid directory
id /nonexistent/path

# Error: Wrong command
compile_id project  # Not the correct command
```
