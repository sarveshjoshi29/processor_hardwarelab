// Core 1 UART smoke test (freestanding)
// Writes a short string to UART at 0x2000_0000 then loops.

#define UART_BASE 0x20000000u

static inline void uart_putc(char c) {
    volatile unsigned int *uart = (volatile unsigned int *)UART_BASE;
    while ((*uart) & 1u) {
        // spin
    }
    *(volatile unsigned char *)UART_BASE = (unsigned char)c;
}

int main(void) {
    uart_putc('C');
    uart_putc('1');
    uart_putc(':');
    uart_putc('W');
    uart_putc('o');
    uart_putc('r');
    uart_putc('l');
    uart_putc('d');
    uart_putc('\n');
    for (;;) {
        asm volatile ("nop");
    }
}
