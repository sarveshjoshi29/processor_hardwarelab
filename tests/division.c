// Simple division test for core 1.
// Stores result in shared data memory at 0x404.
#include <stdint.h>

#define OUT_ADDR 0x404u

void _start(void) {
    volatile uint32_t *out = (uint32_t *)OUT_ADDR;
    uint32_t a = 1000;
    uint32_t b = 7;
    uint32_t q = a / b; // Expect 142
    uint32_t r = a % b; // Expect 6

    // Pack quotient and remainder for easy checking.
    *out = (q << 16) | (r & 0xFFFFu);

    // Halt: tight loop
    while (1) {
        __asm__ volatile ("nop");
    }
}
