/*
 * ============================================================================
 * Core 1 — Fibonacci(10) via UART
 * ============================================================================
 * This is the EQUIVALENT C code for what Core 1 executes on the FPGA.
 * The actual FPGA binary is hand-assembled RV32IM machine code generated
 * by gen_hex_soc.py, but this C code represents the same algorithm.
 *
 * Core 1 starts at PC = 0x0000_0200
 * UART TX peripheral is mapped at 0x2000_0000:
 *   - Write byte to 0x2000_0000 → transmit character
 *   - Read from 0x2000_0000 → bit[0] = busy flag
 *
 * Both cores compute IN PARALLEL, but share the UART serially:
 *   Core 1 computes fib(10) while Core 0 is printing,
 *   then Core 1 prints its result after Core 0 finishes.
 * ============================================================================
 */

#define UART_BASE ((volatile unsigned int *)0x20000000)

/* ---- UART send character (blocking) ---- */
void send_char(char c) {
    while (*UART_BASE & 1)   /* poll until not busy */
        ;
    *UART_BASE = (unsigned int)c;
}

/* ---- UART send string ---- */
void send_string(const char *s) {
    while (*s) {
        send_char(*s);
        s++;
    }
}

/* ---- Print unsigned integer as decimal ---- */
void print_decimal(unsigned int val) {
    if (val == 0) {
        send_char('0');
        return;
    }

    char buf[12];
    int count = 0;

    while (val > 0) {
        buf[count++] = '0' + (val % 10);
        val /= 10;
    }

    for (int i = count - 1; i >= 0; i--) {
        send_char(buf[i]);
    }
}

/* ---- Synchronization (done via lr.w/sc.w on shared memory) ---- */
#define SYNC_C0_DONE ((volatile unsigned int *)0x00000400)
#define SYNC_C1_DONE ((volatile unsigned int *)0x00000404)

void signal_done(volatile unsigned int *flag) {
    *flag = 1;  /* In actual hardware: uses lr.w/sc.w atomic write */
}

void wait_for(volatile unsigned int *flag) {
    while (*flag == 0)  /* In actual hardware: uses lr.w polling */
        ;
}

/* ============================================================================
 *  MAIN — Core 1 Entry Point
 * ============================================================================ */
void core1_main(void) {

    /* ---- Wait for Core 0 to finish its UART output ---- */
    /* While waiting, Core 1 can compute in parallel! */
    /* (In practice, fib(10) finishes instantly; the wait is for UART sharing) */

    /* ---- Compute Fibonacci(10) ---- */
    unsigned int f0 = 0, f1 = 1, fn;
    for (int i = 2; i <= 10; i++) {
        fn = f0 + f1;
        f0 = f1;
        f1 = fn;
    }
    /* f1 = fib(10) = 55 */

    /* ---- Store result to data memory (for debug) ---- */
    *((volatile unsigned int *)0x00000104) = f1;

    /* ---- Wait for Core 0's signal before printing ---- */
    wait_for(SYNC_C0_DONE);

    /* ---- Print: "C1:fib=55" ---- */
    send_string("C1:fib=");
    print_decimal(f1);
    send_string("\r\n");

    /* ---- Signal Core 0: "I'm done printing" ---- */
    signal_done(SYNC_C1_DONE);

    /* ---- Halt (infinite loop) ---- */
    while (1);
}
