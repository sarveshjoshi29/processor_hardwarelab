#include "lib.h"

void print_str(const char* str) {
    while (*str) {
        while ((UART_BASE[0] & 1) != 0) {} // Wait for UART ready
        UART_BASE[0] = *str++;
    }
}

void print_int(int val) {
    if (val == 0) {
        print_str("0");
        return;
    }
    if (val < 0) {
        print_str("-");
        val = -val;
    }
    char buf[12];
    int i = 10;
    buf[11] = '\0';
    while (val > 0) {
        buf[i--] = (val % 10) + '0';
        val /= 10;
    }
    print_str(&buf[i+1]);
}

// ------------------------------------------------------------------
// REAL HARDWARE MUTEX IMPLEMENTATION
// ------------------------------------------------------------------

void mutex_lock(mutex_t* m) {
    int expected, result;
    while(1) {
        __asm__ volatile (
            "1: \n\t"
            "lr.w %[expected], (%[addr])\n\t"
            "bnez %[expected], 1b\n\t"        // If lock is 1 (taken), keep spinning
            "li %[expected], 1\n\t"           // Try to set lock to 1
            "sc.w %[result], %[expected], (%[addr])\n\t"
            "bnez %[result], 1b\n\t"          // If SC fails due to hardware conflict, retry
            : [expected] "=&r" (expected), [result] "=&r" (result)
            : [addr] "r" (&m->state)
            : "memory"
        );
        __asm__ volatile ("fence rw, rw" ::: "memory");
        break; // Successfully acquired lock!
    }
}

void mutex_unlock(mutex_t* m) {
    int expected, result;
    __asm__ volatile ("fence rw, rw" ::: "memory");
    __asm__ volatile (
        "1: \n\t"
        "lr.w %[expected], (%[addr])\n\t"
        "li %[expected], 0\n\t"               // Set lock to 0
        "sc.w %[result], %[expected], (%[addr])\n\t" // Write securely to memory, bypassing cache
        "bnez %[result], 1b\n\t"
        : [expected] "=&r" (expected), [result] "=&r" (result)
        : [addr] "r" (&m->state)
        : "memory"
    );
}

// ------------------------------------------------------------------
// SHARED MEMORY READ/WRITE (Bypassing Write-Back L1 Cache)
// ------------------------------------------------------------------

int atomic_read(volatile int* addr) {
    int val;
    __asm__ volatile (
        "fence rw, rw\n\t"
        "lr.w %[val], (%[addr])"
        : [val] "=r" (val)
        : [addr] "r" (addr)
        : "memory"
    );
    return val;
}

void atomic_write(volatile int* addr, int val) {
    int expected, result;
    __asm__ volatile (
        "fence rw, rw\n\t"
        "1: \n\t"
        "lr.w %[expected], (%[addr])\n\t"
        "sc.w %[result], %[val], (%[addr])\n\t"
        "bnez %[result], 1b\n\t"
        : [expected] "=&r" (expected), [result] "=&r" (result)
        : [addr] "r" (addr), [val] "r" (val)
        : "memory"
    );
}
