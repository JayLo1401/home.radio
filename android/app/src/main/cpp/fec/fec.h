/* Minimal public API header for the char (8-bit symbol) Reed-Solomon codec,
 * Copyright 2003-2004 Phil Karn, KA9Q, LGPL - extracted from libfec's fec.h
 * (github.com/quiet/libfec) since only the char/RS portion is used here. */
#ifndef FEC_H
#define FEC_H

#ifdef __cplusplus
extern "C" {
#endif

void *init_rs_char(int symsize, int gfpoly, int fcr, int prim, int nroots, int pad);
void free_rs_char(void *rs);
int decode_rs_char(void *rs, unsigned char *data, int *eras_pos, int no_eras);

#ifdef __cplusplus
}
#endif

#endif
