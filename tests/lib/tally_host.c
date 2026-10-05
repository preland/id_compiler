#include <stdio.h>
#include "tally.h"

static int failures = 0;
#define CHECK(what, cond) do { if (cond) printf("PASS: %s\n", what); else { printf("FAIL: %s\n", what); failures++; } } while (0)

int main(void) {
    int32_t total = -1;
    CHECK("reset", tally_reset() == 0);
    CHECK("add 3", tally_add(3) == 0);
    CHECK("add 4", tally_add(4) == 0);
    CHECK("the list made by reset is still there two calls later", tally_total(&total) == 0 && total == 7);
    tally_shutdown();
    CHECK("after shutdown, reset starts again", tally_reset() == 0 && tally_add(10) == 0 && tally_total(&total) == 0 && total == 10);
    return failures ? 1 : 0;
}
