#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "kit.h"

static int failures = 0;
#define CHECK(what, cond) do { if (cond) printf("PASS: %s\n", what); else { printf("FAIL: %s\n", what); failures++; } } while (0)

static long rss_kb(void) {
    long pages = 0, resident = 0;
    FILE* f = fopen("/proc/self/statm", "r");
    if (!f) return -1;
    if (fscanf(f, "%ld %ld", &pages, &resident) != 2) resident = -1;
    fclose(f);
    return resident * 4;
}

int main(void) {
    int32_t i32 = 0;
    int64_t i64 = 0;
    char* s = NULL;
    size_t n = 0;
    double* fs = NULL;
    kit_strs strs;
    kit_table tab;
    int32_t a[] = {1, 2, 3}, b[] = {4, 5, 6}, c[] = {1, 2};
    double xs[] = {1.5, -2.0};
    int64_t ws[] = {4000000000LL, 4000000000LL};
    const char* parts[] = {"a", "b", "c"};
    size_t part_lens[] = {1, 1, 1};

    CHECK("int list in, int out", kit_dot(a, 3, b, 3, &i32) == 0 && i32 == 32);
    CHECK("float list in and out, float in", kit_scale(xs, 2, 2.0, &fs, &n) == 0 && n == 2 && fs[0] == 3.0 && fs[1] == -4.0);
    kit_free(fs);
    CHECK("word list in, 64-bit out", kit_wsum(ws, 2, &i64) == 0 && i64 == 8000000000LL);
    CHECK("string list in, string out", kit_join(parts, part_lens, 3, "-", 1, &s, &n) == 0 && n == 5 && strcmp(s, "a-b-c") == 0);
    kit_free(s);
    CHECK("string in, string list out", kit_split("a,b,,c", 6, ",", 1, &strs) == 0 && strs.count == 4 && strs.lens[2] == 0 && strcmp(strs.items[3], "c") == 0);
    kit_strs_free(&strs);
    CHECK("string in, table out", kit_grid("a b\nc", 5, &tab) == 0 && tab.rows == 2 && tab.row[0].count == 2 && strcmp(tab.row[1].items[0], "c") == 0);
    kit_table_free(&tab);
    CHECK("void result that writes the store", kit_stash(3) == 0);
    CHECK("empty list in", kit_dot(a, 0, b, 0, &i32) == 0 && i32 == 0);

    CHECK("index trap is status 1", kit_nth(a, 3, 9, &i32) == 1);
    CHECK("trap message names the fault", strstr(kit_error(), "index 9 out of bounds (len 3)") != NULL);
    CHECK("trap leaves the out empty", i32 == 0);
    CHECK("shorter second list traps", kit_dot(a, 3, c, 2, &i32) == 1);
    CHECK("division by zero is status 1", kit_div(1, 0, &i32) == 1 && strstr(kit_error(), "division by zero") != NULL);
    CHECK("the library works after traps", kit_div(9, 3, &i32) == 0 && i32 == 3);
    CHECK("a success clears the message", kit_error()[0] == '\0');
    CHECK("a NUL in a string is status 2", kit_split("a\0b", 3, ",", 1, &strs) == 2 && strstr(kit_error(), "NUL") != NULL);
    CHECK("a failed call leaves list outs empty", strs.count == 0 && strs.items == NULL);

    {
        long before, after;
        int k, bad = 0;
        kit_dot(a, 3, b, 3, &i32);
        before = rss_kb();
        for (k = 0; k < 200000; k++) {
            if (kit_join(parts, part_lens, 3, "--", 2, &s, &n) != 0) bad++;
            kit_free(s);
            if (kit_nth(a, 3, 7, &i32) != 1) bad++;
            if (kit_stash(100) != 0) bad++;
            if (kit_split("x y z", 5, " ", 1, &strs) != 0) bad++;
            kit_strs_free(&strs);
        }
        after = rss_kb();
        CHECK("800000 calls, a quarter of them traps, return no error", bad == 0);
        printf("rss %ld KB -> %ld KB\n", before, after);
        CHECK("resident memory did not grow by more than 1 MB over 800000 calls", after - before < 1024);
    }
    kit_shutdown();
    CHECK("calls still work after shutdown", kit_div(8, 2, &i32) == 0 && i32 == 4);
    return failures ? 1 : 0;
}
