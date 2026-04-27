#include "lib.h"

// ---------------------------------------------------------
// HARDWARE STRESS TEST & EDGE CASE VALIDATOR
// ---------------------------------------------------------
// This program stresses the SoC by forcing extreme contention
// on the atomic memory bus and UART peripheral.

mutex_t console_lock = {0}; 
mutex_t data_lock = {0};    

volatile int shared_counter = 0;
volatile int contention_array[4] = {0, 0, 0, 0};

// Fast delay for aggressive polling
void fast_delay(int loops) {
    volatile int i = 0;
    while (i < loops) { i++; }
}

void safe_print(const char* str) {
    mutex_lock(&console_lock);
    print_str(str);
    mutex_unlock(&console_lock);
}

// ---------------------------------------------------------
// CORE 0: Aggressive incrementer
// ---------------------------------------------------------
int main() {
    safe_print("[CORE 0] Hardware Stress Test Initiated.\r\n");
    
    // 1. ATOMIC CONTENTION STORM
    // Both cores will rapidly read/write the same addresses without delay
    for(int i = 0; i < 50; i++) {
        // Hammer the same lock
        mutex_lock(&data_lock);
        
        int count = atomic_read(&shared_counter);
        count += 1;
        atomic_write(&shared_counter, count);
        
        // Also hammer an array to stress address decoding during arbitration
        int arr_val = atomic_read(&contention_array[i % 4]);
        atomic_write(&contention_array[i % 4], arr_val + 1);
        
        mutex_unlock(&data_lock);
    }
    
    // 2. UART CONTENTION STORM
    // Spam the UART to test buffer/lock robustness
    for(int i = 0; i < 10; i++) {
        safe_print("[CORE 0] UART SPAM!\r\n");
    }
    
    // Wait for Core 1
    fast_delay(20000); 
    
    mutex_lock(&console_lock);
    print_str("\r\n================================\r\n");
    print_str("[SYSTEM] STRESS TEST COMPLETE.\r\n");
    print_str("[SYSTEM] EXPECTED COUNTER: 100\r\n");
    print_str("[SYSTEM] ACTUAL COUNTER:   ");
    print_int(atomic_read(&shared_counter));
    print_str("\r\n================================\r\n");
    print_perf_counters("Core 0");
    mutex_unlock(&console_lock);
    
    return 0;
}

// ---------------------------------------------------------
// CORE 1: Aggressive incrementer
// ---------------------------------------------------------
void core1_main() {
    safe_print("[CORE 1] Online. Joining Contention Storm.\r\n");
    
    // 1. ATOMIC CONTENTION STORM
    for(int i = 0; i < 50; i++) {
        mutex_lock(&data_lock);
        
        int count = atomic_read(&shared_counter);
        count += 1;
        atomic_write(&shared_counter, count);
        
        int arr_val = atomic_read(&contention_array[(i+2) % 4]);
        atomic_write(&contention_array[(i+2) % 4], arr_val + 1);
        
        mutex_unlock(&data_lock);
    }
    
    // 2. UART CONTENTION STORM
    for(int i = 0; i < 10; i++) {
        safe_print("[CORE 1] UART SPAM!\r\n");
    }
    
    // Print Core 1 performance counters
    mutex_lock(&console_lock);
    print_perf_counters("Core 1");
    mutex_unlock(&console_lock);
}
