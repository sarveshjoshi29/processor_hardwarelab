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

// ---- CSR Performance Counter Reads (Phase 5) ----
// CSR addresses: 0xC00=cycle, 0xC02=instret, 0xC03=icmiss,
//                0xC04=dcmiss, 0xC05=brmiss, 0xC06=stalls

static inline int csr_read_cycle(void) {
    int v; __asm__ volatile ("csrr %0, 0xC00" : "=r"(v)); return v;
}
static inline int csr_read_instret(void) {
    int v; __asm__ volatile ("csrr %0, 0xC02" : "=r"(v)); return v;
}
static inline int csr_read_icmiss(void) {
    int v; __asm__ volatile ("csrr %0, 0xC03" : "=r"(v)); return v;
}
static inline int csr_read_dcmiss(void) {
    int v; __asm__ volatile ("csrr %0, 0xC04" : "=r"(v)); return v;
}
static inline int csr_read_brmiss(void) {
    int v; __asm__ volatile ("csrr %0, 0xC05" : "=r"(v)); return v;
}
static inline int csr_read_stalls(void) {
    int v; __asm__ volatile ("csrr %0, 0xC06" : "=r"(v)); return v;
}

// Print all performance counters over UART
void print_perf_counters(const char* label);

#endif
