#include "lib.h"

// ---------------------------------------------------------
// SHARED DATA STRUCTURES
// ---------------------------------------------------------
mutex_t console_lock = {0};
mutex_t sync_lock = {0};

volatile int finished_cores = 0;

// Input Matrices
int A[2][2] = {
    {1, 2},
    {3, 4}};

int B[2][2] = {
    {5, 6},
    {7, 8}};

// Output Matrix
volatile int C[2][2] = {
    {0, 0},
    {0, 0}};

// Thread-safe print function
void safe_print(const char *str)
{
    mutex_lock(&console_lock);
    print_str(str);
    mutex_unlock(&console_lock);
}

void mark_finished()
{
    mutex_lock(&sync_lock);
    int current = atomic_read(&finished_cores);
    atomic_write(&finished_cores, current + 1);
    mutex_unlock(&sync_lock);
}

// ---------------------------------------------------------
// CORE 0 THREAD: Computes Row 0
// ---------------------------------------------------------
int main()
{
    safe_print("[CORE 0] Matrix Mult Thread Started. Computing Row 0...\r\n");

    // Compute C[0][0] and C[0][1] using atomic_write to bypass cache
    atomic_write(&C[0][0], A[0][0] * B[0][0] + A[0][1] * B[1][0]);
    atomic_write(&C[0][1], A[0][0] * B[0][1] + A[0][1] * B[1][1]);

    // Mark as finished
    mark_finished();

    // Wait for all cores to finish
    while (1)
    {
        mutex_lock(&sync_lock);
        int done = atomic_read(&finished_cores);
        mutex_unlock(&sync_lock);
        if (done == 2)
            break;
    }

    // Print the final result matrix
    mutex_lock(&console_lock);
    print_str("\r\n[SYSTEM] ALL BARE-METAL THREADS FINISHED.\r\n");
    print_str("[SYSTEM] RESULT MATRIX C (2x2):\r\n");

    print_str("[ ");
    print_int(atomic_read(&C[0][0]));
    print_str(" \t");
    print_int(atomic_read(&C[0][1]));
    print_str(" ]\r\n");

    print_str("[ ");
    print_int(atomic_read(&C[1][0]));
    print_str(" \t");
    print_int(atomic_read(&C[1][1]));
    print_str(" ]\r\n\r\n");

    mutex_unlock(&console_lock);

    return 0;
}

// ---------------------------------------------------------
// CORE 1 THREAD: Computes Row 1
// ---------------------------------------------------------
void core1_main()
{
    safe_print("[CORE 1] Matrix Mult Thread Started. Computing Row 1...\r\n");

    // Compute C[1][0] and C[1][1] using atomic_write to bypass cache
    atomic_write(&C[1][0], A[1][0] * B[0][0] + A[1][1] * B[1][0]);
    atomic_write(&C[1][1], A[1][0] * B[0][1] + A[1][1] * B[1][1]);

    // Mark as finished
    mark_finished();

    // Idle loop
    while (1)
    {
        asm volatile("nop");
    }
}
