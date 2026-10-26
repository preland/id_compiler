#include "ch.h"

int id_ch_new(int cap) { return id_chan_new(cap); }
int id_ch_sender(int rx) { return id_chan_sender(rx); }
int id_ch_send(int tx, int v) { return id_chan_send(tx, v); }
int id_ch_wait(int rx) { return id_chan_wait(rx); }
int id_ch_take(int rx) { return id_chan_take(rx); }
void id_ch_close(int h) { id_chan_close(h); }
int id_th_spawn(int (*f)(int), int arg) { return id_thr_spawn(f, arg); }
int id_th_spawn_tx(int (*f)(int), int arg) { return id_thr_spawn(f, arg); }
int id_th_join(int h) { return id_thr_join(h); }
