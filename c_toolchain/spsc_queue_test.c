#include "lib.h"

// ---------------------------------------------------------
// SPSC LOCK-FREE QUEUE TEST
// ---------------------------------------------------------

#define QUEUE_SIZE 4

// The Queue state
// We must use atomic_read / atomic_write for all shared state
// to bypass the L1 caches since there is no cache coherence protocol.
volatile int queue_data[QUEUE_SIZE];
volatile int queue_head = 0; // Read by Producer, Written by Consumer
volatile int queue_tail = 0; // Read by Consumer, Written by Producer

mutex_t console_lock = {0}; 

void fast_delay(int loops) {
    volatile int i = 0;
    while (i < loops) { i++; }
}

void safe_print(const char* str) {
    mutex_lock(&console_lock);
    print_str(str);
    mutex_unlock(&console_lock);
}

void safe_print_int(const char* prefix, int val, const char* suffix) {
    mutex_lock(&console_lock);
    print_str(prefix);
    print_int(val);
    print_str(suffix);
    mutex_unlock(&console_lock);
}

// ---------------------------------------------------------
// CORE 0: PRODUCER
// ---------------------------------------------------------
int main() {
    safe_print("[CORE 0] Producer Online.\r\n");
    
    // Send 5 messages: 100, 200, 300, 400, 500
    for(int i = 1; i <= 5; i++) {
        int msg = i * 100;
        
        int tail = atomic_read(&queue_tail);
        int next_tail = (tail + 1) % QUEUE_SIZE;
        
        // Spin while queue is full
        while(atomic_read(&queue_head) == next_tail) {
            // Queue full, wait
        }
        
        // Write data using atomic_write to bypass cache
        atomic_write(&queue_data[tail], msg);
        
        // Update tail pointer using atomic_write to publish data
        atomic_write(&queue_tail, next_tail);
        
        safe_print_int("[PRODUCER] Sent: ", msg, "\r\n");
        fast_delay(200); // Wait a bit to simulate work
    }
    
    safe_print("[CORE 0] Finished Producing.\n");
    
    // Print Core 0 performance counters
    mutex_lock(&console_lock);
    print_perf_counters("Core 0");
    mutex_unlock(&console_lock);
    
    // Keep Core 0 alive while Core 1 finishes
    fast_delay(20000);
    return 0;
}

// ---------------------------------------------------------
// CORE 1: CONSUMER
// ---------------------------------------------------------
void core1_main() {
    safe_print("[CORE 1] Consumer Online.\r\n");
    
    // Expecting 5 messages
    for(int i = 0; i < 5; i++) {
        int head = atomic_read(&queue_head);
        
        // Spin while queue is empty
        while(atomic_read(&queue_tail) == head) {
            // Queue empty, wait
        }
        
        // Read data using atomic_read to bypass cache
        int msg = atomic_read(&queue_data[head]);
        
        // Update head pointer to consume the item
        int next_head = (head + 1) % QUEUE_SIZE;
        atomic_write(&queue_head, next_head);
        
        safe_print_int("    [CONSUMER] Received: ", msg, "\r\n");
    }
    
    safe_print("[CORE 1] Finished Consuming.\n");
    
    // Print Core 1 performance counters
    mutex_lock(&console_lock);
    print_perf_counters("Core 1");
    mutex_unlock(&console_lock);
}
