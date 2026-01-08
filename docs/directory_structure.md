# Project Structure

The file structure of an id project is relatively simple. Within each subdirectory, there can be at most 3 combined subdirectories and files. In other words, you can have 3 subdirectories, or 3 files, or 2 files and 1 subdirectory, and so forth. If a subdirectory has more than three files and subdirectories, this is a compiler error.

It should be noted that "subdirectories" only refer to directories that are utilized in compilation. As such, the "build", "docs", "resources", and any hidden directories/files do not contribute to the count. It should be noted that a empty subdirectory within the build root or non-id file in an otherwise valid subdirectory is a compiler error.

## Examples

### Proper Structure

```
project/
├── main.id
├── utils.id
└── helpers/
    ├── helper1.id
    ├── helper2.id
    └── subhelpers/
        └── deep.id
```

### Improper Structure

```
project/
├── main.id
├── utils.id
├── helpers.id
├── extra.id
└── another.id  # More than 3 files/directories at root level
```

```
project/
├── main.id
├── utils.id
└── empty_dir/  # Empty directory - error
```
