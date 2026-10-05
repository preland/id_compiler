/* idl_pre.h -- what `idc PATH --lib` puts in front of a program's generated C.

   A library is one translation unit, assembled in this order:

     <NAME>.h        the public header (idc/tools/libgen writes it)
     idl_pre.h       this file: the system headers, and the trap redirection
     <program C>     what idc --emit-c would write, with no `main`
     idl.c           the entry-point machinery, which needs the program's
                     runtime statics (the arena, IdList, id_str_from)
     wrappers        one C-ABI function per exported id function (libgen)

   The system headers the program's C includes are included here first, so the
   macros below cannot reach into a header and rewrite a declaration. The
   program is compiled with -DIDL_LIB=NAME; every runtime entry point a host
   sees is NAME_free, NAME_error and so on, so two id libraries can sit in one
   process. See docs/INTEROP.md, "id as a library". */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdint.h>
#include <stddef.h>
#include <limits.h>
#include <setjmp.h>
#include <pthread.h>
#include <termios.h>
#include <unistd.h>
#include <time.h>

#define IDL_CAT2(a, b) a##_##b
#define IDL_CAT(a, b) IDL_CAT2(a, b)
#define idl_free IDL_CAT(IDL_LIB, free)
#define idl_error IDL_CAT(IDL_LIB, error)
#define idl_strs_free IDL_CAT(IDL_LIB, strs_free)
#define idl_table_free IDL_CAT(IDL_LIB, table_free)
#define idl_shutdown IDL_CAT(IDL_LIB, shutdown)
#define idl_strs_t IDL_CAT(IDL_LIB, strs)
#define idl_table_t IDL_CAT(IDL_LIB, table)

#define IDL_API __attribute__((visibility("default")))

/* Every trap in the id runtime is `fprintf(stderr, "id: ...")` and then
   `exit(1)`. Inside a library call those two become a message the host can ask
   for and a longjmp back to the entry point; outside one they are what they
   always were. */
static _Noreturn void idl_exit(int code);
static int idl_fprintf(FILE* stream, const char* fmt, ...);
#define exit(code) idl_exit(code)
#define fprintf idl_fprintf
