#ifndef CH_H
#define CH_H
extern int id_chan_new(int cap);
extern int id_chan_sender(int rx);
extern int id_chan_send(int tx, int v);
extern int id_chan_wait(int rx);
extern int id_chan_take(int rx);
extern void id_chan_close(int h);
extern int id_thr_spawn(int (*f)(int), int arg);
extern int id_thr_join(int h);
int id_ch_new(int cap);
int id_ch_sender(int rx);
int id_ch_send(int tx, int v);
int id_ch_wait(int rx);
int id_ch_take(int rx);
void id_ch_close(int h);
int id_th_spawn(int (*f)(int), int arg);
int id_th_join(int h);
#endif
