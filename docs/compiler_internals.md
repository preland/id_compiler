# Compiler Internals

This document should answer the following questions:

- How is the id compiler structured (e.g., lexer, parser, codegen)?
- How does LLVM integration work?
- What is the compilation pipeline?
- How are optimizations performed?
- What are the target platforms and architectures?
- How are errors detected and reported?
- What are the performance trade-offs?
- How can the compiler be extended or customized?

This is a **very** rough structure of how the id compiler works (basically incomplete pseudo-id code):

fn main(int argc, string[] argv)
    if(argc ==1)
        compile_and_link(pwd )
    else
        handle_input(argv)
return int 0

fn handle_input()
Check arguments
if argv[1] == “—help” or arguments don’t make sense
    print help
else
    // run compilation with arguments

fn compile_and_link()
    //compile files recursively
    //link everything recursively
return nil

fn compile()
    //get list of items within given directory
    //compile all files (unlinked)
    //Recurse into relevant subdirectories
return nil

fn compile_file()
    //Set string variable to the contents of given file
    //Validate the file
    //Continue compilation
return nil

fn validate_file()
    //Tokenize the string into an array of tokens
    //Check function names against existing list
    //Check rest of syntax

fn validate_lines()
    //Divide tokens into lines
    //If the previous failed, begin failure thing
    //Check rest of syntax

fn validate_groupings
    //Divide lines into functions and objects
    //If the previous failed, begin failure thing
    //Else return that the file is legitimate

fn divide_lines()
    //make list of token lists by splitting on new line token
    //Check that each line is valid
    //If failed, begin failure thing
    //Else return that the lines are legitimate

fn divide_groupings()
    //Make list of token list lists by splitting into groups enclosed by untabbed lines
    //Check that each group is a valid group
    //If failed, begin failure thing
    //Else return that the groups are legitimate

Obj Token{
    string token
}
Obj Line {
    Token[] line
}
Obj Grouping {
    Line[] grouping
}