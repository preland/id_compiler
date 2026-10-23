/* idl.c -- the entry-point machinery of an id library (see idl_pre.h for where
   this sits). It is included after the program's generated C because it
   reaches the program's own runtime statics: the pool (id_pool_chunks, id_pool_fl,
   id_arena_head, IdAllocHdr), the flat store (id_store*), IdList, id_str_from.

   One call into the library is:

     lock          the runtime has global state, so calls are serialised
     setjmp        a trap anywhere below comes back here, as an error code
     init (once)   idc_const_init: the conf.id constants a program reads
     frame         scoped libraries: mark the pool's chunks and the large-block
                   list, so what the call allocates can be freed when it returns
     convert in    host data -> id strings and lists, allocated in the frame
     the id call
     convert out   id result -> malloc'd memory the host owns
     release       scoped: free the frame; reset the flat store's high-water
                   mark and zero what the call wrote to it
     unlock

   A scoped library (the default) therefore keeps nothing between calls: no
   id heap value and no store contents. IDL_KEEP (idc --lib-state) frees
   nothing per call and keeps everything until NAME_shutdown(). */
#ifdef IDL_KEEP
#define IDL_SCOPED 0
#else
#define IDL_SCOPED 1
#endif

static pthread_mutex_t idl_lock = PTHREAD_MUTEX_INITIALIZER;
static jmp_buf idl_jb;
static int idl_active = 0;
static int idl_inited = 0;
static int idl_framed = 0;
static long long idl_store_mark = 1;
static IdAllocHdr idl_frame;
static IdChunk* idl_pool_mark = NULL;
static _Thread_local int idl_code = 0;
static _Thread_local char idl_msg[512];

static void idl_set_msg(const char* fmt, va_list ap) {
    size_t n;
    if (idl_msg[0]) return;
    vsnprintf(idl_msg, sizeof idl_msg, fmt, ap);
    n = strlen(idl_msg);
    while (n > 0 && idl_msg[n - 1] == '\n') idl_msg[--n] = '\0';
}

static int idl_fprintf(FILE* stream, const char* fmt, ...) {
    va_list ap;
    int r;
    va_start(ap, fmt);
    if (stream == stderr && idl_active) {
        idl_set_msg(fmt, ap);
        r = (int)strlen(idl_msg);
    } else {
        r = vfprintf(stream, fmt, ap);
    }
    va_end(ap);
    return r;
}

static _Noreturn void idl_exit(int code) {
    if (!idl_active) (exit)(code);
    if (!idl_msg[0]) snprintf(idl_msg, sizeof idl_msg, "id: exit(%d) called inside a library call", code);
    longjmp(idl_jb, 1);
}

static _Noreturn void idl_argerr(const char* what) {
    idl_code = 2;
    snprintf(idl_msg, sizeof idl_msg, "%s", what);
    longjmp(idl_jb, 1);
}

static _Noreturn void idl_oom(void) {
    snprintf(idl_msg, sizeof idl_msg, "out of memory while copying a result out of the id heap");
    longjmp(idl_jb, 1);
}

static void idl_begin(void) {
    if (idl_inited != 2) {
        idl_inited = 1;
#ifdef IDL_HAS_CONST_INIT
        idc_const_init();
#endif
        idl_inited = 2;
    }
    if (IDL_SCOPED) {
        id_arena_link(&idl_frame);
        idl_pool_mark = id_pool_chunks;
        memset(id_pool_fl, 0, sizeof id_pool_fl);
        id_pool_bump = NULL;
        id_pool_left = 0;
        idl_store_mark = id_store_used;
        idl_framed = 1;
    }
}

static void idl_release(void) {
    IdAllocHdr* h = id_arena_head;
    IdAllocHdr* below = idl_frame.next;
    IdAllocHdr* store_hdr = id_store ? (IdAllocHdr*)(void*)id_store - 1 : NULL;
    id_arena_head = below;
    if (below) below->prev = NULL;
    while (h != &idl_frame) {
        IdAllocHdr* nx = h->next;
        if (h == store_hdr) {
            h->prev = NULL;
            h->next = id_arena_head;
            if (id_arena_head) id_arena_head->prev = h;
            id_arena_head = h;
        } else {
            free(h);
        }
        h = nx;
    }
    while (id_pool_chunks != idl_pool_mark) {
        IdChunk* c = id_pool_chunks;
        id_pool_chunks = c->next;
        free(c);
    }
    memset(id_pool_fl, 0, sizeof id_pool_fl);
    id_pool_bump = NULL;
    id_pool_left = 0;
    if (id_store_used > idl_store_mark) {
        memset(id_store + idl_store_mark, 0, (size_t)(id_store_used - idl_store_mark));
        id_store_used = idl_store_mark;
    }
    idl_framed = 0;
}

static int idl_done(int code) {
    idl_active = 0;
    if (idl_framed) idl_release();
    pthread_mutex_unlock(&idl_lock);
    return code;
}

#define IDL_BEGIN \
    pthread_mutex_lock(&idl_lock); \
    idl_code = 1; \
    idl_msg[0] = '\0'; \
    if (setjmp(idl_jb)) return idl_done(idl_code); \
    idl_active = 1; \
    idl_begin();
#define IDL_END return idl_done(0);

IDL_API const char* idl_error(void) { return idl_msg; }

IDL_API void idl_free(void* p) { free(p); }

IDL_API void idl_strs_free(idl_strs_t* s) {
    if (!s) return;
    free(s->items);
    s->items = NULL;
    s->lens = NULL;
    s->count = 0;
}

IDL_API void idl_table_free(idl_table_t* t) {
    size_t i;
    if (!t) return;
    for (i = 0; i < t->rows; i++) idl_strs_free(&t->row[i]);
    free(t->row);
    t->row = NULL;
    t->rows = 0;
}

IDL_API void idl_shutdown(void) {
    pthread_mutex_lock(&idl_lock);
    id_arena_free_all();
    id_store = NULL;
    id_store_used = 1;
    id_store_cap = 0;
    idl_inited = 0;
    pthread_mutex_unlock(&idl_lock);
}

static char* idl_in_str(const char* p, size_t n) {
    if (n && !p) idl_argerr("a string argument is NULL but its length is not zero");
    if (n && memchr(p, 0, n)) idl_argerr("a string argument contains a NUL byte; an id string cannot hold one (pass binary data as an int list)");
    return id_str_from(p ? p : "", n);
}

static IdBytes* idl_in_bytes(const uint8_t* p, size_t n) {
    IdBytes* B;
    if (n && !p) idl_argerr("a bytes argument is NULL but its length is not zero");
    if (n > (size_t)INT_MAX) idl_argerr("a bytes argument is longer than an id bytes value can hold (2^31 - 1 bytes)");
    B = id_bytes_new((int)n);
    if (n) memcpy(B->data, p, n);
    return B;
}

static IdList* idl_list_make(size_t n) {
    if (n > (size_t)INT_MAX / 2) idl_argerr("a list argument is longer than an id list can hold (2^30 elements)");
    return id_list_sized((int)n);
}

static IdList* idl_in_ints(const int32_t* p, size_t n) {
    size_t i;
    IdList* L;
    if (n && !p) idl_argerr("a list argument is NULL but its length is not zero");
    L = idl_list_make(n);
    for (i = 0; i < n; i++) L->data[i] = (long long)p[i];
    return L;
}

static IdList* idl_in_words(const int64_t* p, size_t n) {
    size_t i;
    IdList* L;
    if (n && !p) idl_argerr("a list argument is NULL but its length is not zero");
    L = idl_list_make(n);
    for (i = 0; i < n; i++) L->data[i] = (long long)p[i];
    return L;
}

static IdList* idl_in_floats(const double* p, size_t n) {
    size_t i;
    IdList* L;
    if (n && !p) idl_argerr("a list argument is NULL but its length is not zero");
    L = idl_list_make(n);
    for (i = 0; i < n; i++) L->data[i] = id_box_f(p[i]);
    return L;
}

static IdList* idl_in_strs(const char* const* ps, const size_t* ns, size_t count) {
    size_t i;
    IdList* L;
    if (count && (!ps || !ns)) idl_argerr("a string list argument has a NULL array but a nonzero count");
    L = idl_list_make(count);
    for (i = 0; i < count; i++) L->data[i] = (long long)(intptr_t)idl_in_str(ps[i], ns[i]);
    return L;
}

static void idl_out_str(char** out, size_t* out_len, const char* s) {
    size_t n = id_slen(s);
    char* r = (char*)malloc(n + 1);
    if (!r) idl_oom();
    memcpy(r, s, n);
    r[n] = '\0';
    *out = r;
    *out_len = n;
}

static void idl_out_bytes(uint8_t** out, size_t* out_len, IdBytes* B) {
    size_t n = (size_t)id_bytes_len(B);
    uint8_t* r = (uint8_t*)malloc(n ? n : 1);
    if (!r) idl_oom();
    if (n) memcpy(r, B->data, n);
    *out = r;
    *out_len = n;
}

static void* idl_out_cells(size_t n, size_t width) {
    void* r = malloc(n ? n * width : 1);
    if (!r) idl_oom();
    return r;
}

static void idl_out_ints(int32_t** out, size_t* out_len, IdList* L) {
    size_t i, n = (size_t)id_list_len(L);
    int32_t* r = (int32_t*)idl_out_cells(n, sizeof(int32_t));
    for (i = 0; i < n; i++) r[i] = (int32_t)L->data[i];
    *out = r;
    *out_len = n;
}

static void idl_out_words(int64_t** out, size_t* out_len, IdList* L) {
    size_t i, n = (size_t)id_list_len(L);
    int64_t* r = (int64_t*)idl_out_cells(n, sizeof(int64_t));
    for (i = 0; i < n; i++) r[i] = (int64_t)L->data[i];
    *out = r;
    *out_len = n;
}

static void idl_out_floats(double** out, size_t* out_len, IdList* L) {
    size_t i, n = (size_t)id_list_len(L);
    double* r = (double*)idl_out_cells(n, sizeof(double));
    for (i = 0; i < n; i++) r[i] = id_unbox_f(L->data[i]);
    *out = r;
    *out_len = n;
}

static int idl_strs_make(idl_strs_t* out, IdList* L) {
    size_t i, n = (size_t)id_list_len(L), bytes = 0;
    char* block;
    char* at;
    out->count = 0;
    out->items = NULL;
    out->lens = NULL;
    if (n == 0) return 0;
    for (i = 0; i < n; i++) bytes += id_slen((const char*)(intptr_t)L->data[i]) + 1;
    block = (char*)malloc(n * (sizeof(char*) + sizeof(size_t)) + bytes);
    if (!block) return -1;
    out->items = (char**)(void*)block;
    out->lens = (size_t*)(void*)(block + n * sizeof(char*));
    at = block + n * (sizeof(char*) + sizeof(size_t));
    for (i = 0; i < n; i++) {
        const char* s = (const char*)(intptr_t)L->data[i];
        size_t len = id_slen(s);
        memcpy(at, s, len);
        at[len] = '\0';
        out->items[i] = at;
        out->lens[i] = len;
        at += len + 1;
    }
    out->count = n;
    return 0;
}

static void idl_out_strs(idl_strs_t* out, IdList* L) {
    if (idl_strs_make(out, L) != 0) idl_oom();
}

static void idl_out_table(idl_table_t* out, IdList* L) {
    size_t i, n = (size_t)id_list_len(L);
    idl_strs_t* rows = (idl_strs_t*)calloc(n ? n : 1, sizeof(idl_strs_t));
    if (!rows) idl_oom();
    for (i = 0; i < n; i++) {
        if (idl_strs_make(&rows[i], (IdList*)(intptr_t)L->data[i]) != 0) {
            while (i > 0) idl_strs_free(&rows[--i]);
            free(rows);
            idl_oom();
        }
    }
    out->rows = n;
    out->row = rows;
}
