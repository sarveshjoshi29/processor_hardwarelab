// Simple factorial test for core 0.
// Stores result in shared data memory at 0x400.
#include <stdint.h>

#define OUT_ADDR 0x400u

void _start(void) {
    volatile uint32_t *out = (uint32_t *)OUT_ADDR;
    uint32_t n = 6;
    uint32_t acc = 1;

    while (n > 1) {
        acc *= n;
        n--;
    }

    *out = acc; // Expect 720 for 6!

    // Halt: tight loop
    while (1) {
        __asm__ volatile ("nop");
    }
}
