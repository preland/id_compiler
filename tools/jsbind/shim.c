
/* ---- the JS binding shim (idc/tools/jsbind, docs/INTEROP.md) ----------------
   `idc --target wasm` appends this to the C target's output before compiling it
   for wasm32-wasi, so it sees the runtime's static helpers. It exports what the
   generated <name>.mjs cannot do from the outside: build a string or a list the
   runtime will accept, say what layout those have, and flush stdout. Everything
   else crosses by reading and writing linear memory at the offsets idw_abi
   reports, which the module checks once at load. */
#include <stddef.h>

#define IDW_EXPORT(n) __attribute__((export_name(n), used))

IDW_EXPORT("idw_abi") int idw_abi(void) {
    return (int)sizeof(IdList) | ((int)offsetof(IdList, data) << 8)
         | ((int)sizeof(long long) << 16) | ((int)sizeof(size_t) << 24);
}

IDW_EXPORT("idw_str") char* idw_str(int n) {
    return id_str_new((size_t)n);
}

IDW_EXPORT("idw_list") IdList* idw_list(int n) {
    IdList* L = id_list_new();
    if (n > L->cap) {
        L->data = (long long*)id_realloc(L->data, id_mul_check(sizeof(long long), (size_t)n, "list"));
        L->cap = n;
    }
    memset(L->data, 0, sizeof(long long) * (size_t)(n > 0 ? n : 0));
    L->len = n;
    return L;
}

IDW_EXPORT("idw_span") unsigned char* idw_span(long long addr, long long n) {
    return id_store_span(addr, n);
}

IDW_EXPORT("idw_flush") void idw_flush(void) {
    fflush(stdout);
}

IDW_EXPORT("idw_release_str") void idw_release_str(char* s) {
    id_block_free((char*)s - sizeof(size_t));
}

IDW_EXPORT("idw_release_list") void idw_release_list(IdList* L) {
    id_list_free(L);
}
