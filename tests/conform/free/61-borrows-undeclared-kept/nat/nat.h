#ifndef NAT_H
#define NAT_H
typedef struct { int len, cap; long long* data; } IdList;
int id_nat_sum(IdList* xs);
#endif
