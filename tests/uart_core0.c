// Core 0 UART smoke test (freestanding)
// Writes a short string to UART at 0x2000_0000 then loops.

#define UART_BASE 0x20000000u

static inline void uart_putc(char c) {
    volatile unsigned int *uart = (volatile unsigned int *)UART_BASE;
    // busy bit is returned on reads: {31'b0, busy}
    while ((*uart) & 1u) {
        // spin
    }
    // byte write
    *(volatile unsigned char *)UART_BASE = (unsigned char)c;
}

int main(void) {
    // NOTE: string literals live in .rodata, but the hex flow only emits .text.
    // Emit characters as immediates so everything stays in .text.
    uart_putc('C');
    uart_putc('0');
    uart_putc(':');
    uart_putc('H');
    uart_putc('e');
    uart_putc('l');
    uart_putc('l');
    uart_putc('o');
    uart_putc('\n');
    for (;;) {
        // halt-like spin
        asm volatile ("nop");
    }
}
