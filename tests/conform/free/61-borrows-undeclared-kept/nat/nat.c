#include "nat.h"

int id_nat_sum(IdList* xs) {
    int s = 0;
    for (int i = 0; i < xs->len; i++) s += (int)xs->data[i];
    return s;
}
