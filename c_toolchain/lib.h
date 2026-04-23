#ifndef LIB_H
#define LIB_H

#define UART_BASE ((volatile int*)0x20000000)

// A real OS-level Hardware Spinlock Mutex
typedef struct {
    volatile int state;
} mutex_t;

void print_str(const char* str);
void print_int(int val);

// Atomic Hardware Mutex operations
void mutex_lock(mutex_t* m);
void mutex_unlock(mutex_t* m);

// Cache-bypassing Shared Memory operations
int atomic_read(volatile int* addr);
void atomic_write(volatile int* addr, int val);

#endif
