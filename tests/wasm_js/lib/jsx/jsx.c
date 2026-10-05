#include "jsx.h"
#include <ctype.h>
#include <stdlib.h>
#include <string.h>

int id_jsx_twice(int n) { return n * 2; }

char* id_jsx_shout(char* s) {
    size_t n = strlen(s);
    char* t = (char*)malloc(n + 2);
    for (size_t i = 0; i < n; i++) t[i] = (char)toupper((unsigned char)s[i]);
    t[n] = '!';
    t[n + 1] = '\0';
    char* r = id_str_of_cstr(t);
    free(t);
    return r;
}

int id_jsx_fill(IdList* xs, int n) {
    int i = 0;
    for (; i < n && i < xs->len; i++) xs->data[i] = (long long)i * i;
    return i;
}
