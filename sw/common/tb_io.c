/* tb_io.c - console and exit for the testbench memory model (tb/axil_mem.v) */
#include <stdint.h>
#define TB_TOHOST (*(volatile uint32_t *)0xF0000000)
#define TB_PUTC   (*(volatile uint32_t *)0xF0000004)
void putchar_raw(int c) { TB_PUTC = (uint32_t)c; }
void _exit(int code) { TB_TOHOST = (uint32_t)code; for (;;) { } }
