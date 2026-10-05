#include <stdio.h>
#include <string.h>
#include "csv.h"

static int failures = 0;
#define CHECK(what, cond) do { if (cond) printf("PASS: %s\n", what); else { printf("FAIL: %s\n", what); failures++; } } while (0)

int main(void) {
    const char* text = "name,qty,note\nwidget,3,\"a, b\"\ngadget,4.5,plain\n";
    size_t len = strlen(text);
    csv_table rows;
    csv_strs col, errs;
    double sum = 0;
    char* line = NULL;
    size_t line_len = 0;
    const char* fields[] = {"x", "y,z", "say \"hi\""};
    size_t lens[] = {1, 3, 8};

    CHECK("csv_rows parses", csv_rows(text, len, 44, &rows) == 0 && rows.rows == 3 && rows.row[0].count == 3);
    CHECK("a quoted field keeps its comma", strcmp(rows.row[1].items[2], "a, b") == 0);
    csv_table_free(&rows);
    CHECK("csv_col", csv_col(text, len, 44, 0, &col) == 0 && col.count == 3 && strcmp(col.items[2], "gadget") == 0);
    csv_strs_free(&col);
    CHECK("csv_sum skips the header and non-numbers", csv_sum(text, len, 44, 1, &sum) == 0 && sum == 7.5);
    CHECK("csv_errors is empty for a sound text", csv_errors(text, len, 44, &errs) == 0 && errs.count == 0);
    csv_strs_free(&errs);
    CHECK("csv_errors names a fault", csv_errors("a,b\n\"never", 10, 44, &errs) == 0 && errs.count == 1 && strstr(errs.items[0], "never closed") != NULL);
    csv_strs_free(&errs);
    CHECK("csv_line quotes", csv_line(fields, lens, 3, 44, &line, &line_len) == 0 && strcmp(line, "x,\"y,z\",\"say \"\"hi\"\"\"\n") == 0);
    csv_free(line);
    CHECK("csv_cell out of range is a trap, not an exit", csv_cell(text, len, 44, 9, 0, &line, &line_len) == 1 && strstr(csv_error(), "out of bounds") != NULL);
    CHECK("and the library goes on", csv_cell(text, len, 44, 1, 0, &line, &line_len) == 0 && strcmp(line, "widget") == 0);
    csv_free(line);
    return failures ? 1 : 0;
}
