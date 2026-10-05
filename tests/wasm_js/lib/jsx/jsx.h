#ifndef JSX_H
#define JSX_H
typedef struct { int len, cap; long long* data; } IdList;
extern char* id_str_of_cstr(const char* p);
int id_jsx_twice(int n);
char* id_jsx_shout(char* s);
int id_jsx_fill(IdList* xs, int n);
#endif
