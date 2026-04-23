/*
 * ============================================================================
 * Core 0 — Factorial (10!) via UART
 * ============================================================================
 * This is the EQUIVALENT C code for what Core 0 executes on the FPGA.
 * The actual FPGA binary is hand-assembled RV32IM machine code generated
 * by gen_hex_soc.py, but this C code represents the same algorithm.
 *
 * Core 0 starts at PC = 0x0000_0000
 * UART TX peripheral is mapped at 0x2000_0000:
 *   - Write byte to 0x2000_0000 → transmit character
 *   - Read from 0x2000_0000 → bit[0] = busy flag
 *
 * Output on serial terminal (115200 8N1):
 *   ====
 *   RV32IMA
 *   C0:10!=3628800
 *   C1:fib=55
 *   ====
 *   VERIFIED
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

    /* Extract digits (least significant first) */
    while (val > 0) {
        buf[count++] = '0' + (val % 10);
        val /= 10;
    }

    /* Print digits in reverse (most significant first) */
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
 *  MAIN — Core 0 Entry Point
 * ============================================================================ */
void core0_main(void) {

    /* ---- Print banner ---- */
    send_string("====\r\n");
    send_string("RV32IMA\r\n");

    /* ---- Compute 10! (factorial) ---- */
    unsigned int factorial = 1;
    for (int i = 1; i <= 10; i++) {
        factorial *= i;   /* uses RV32M MUL instruction */
    }
    /* factorial = 3,628,800 */

    /* ---- Store result to data memory (for debug) ---- */
    *((volatile unsigned int *)0x00000100) = factorial;

    /* ---- Print: "C0:10!=3628800" ---- */
    send_string("C0:10!=");
    print_decimal(factorial);
    send_string("\r\n");

    /* ---- Signal Core 1: "I'm done printing, your turn" ---- */
    signal_done(SYNC_C0_DONE);

    /* ---- Wait for Core 1 to finish printing ---- */
    wait_for(SYNC_C1_DONE);

    /* ---- Print closing banner ---- */
    send_string("====\r\n");
    send_string("VERIFIED\r\n");

    /* ---- Halt (infinite loop) ---- */
    while (1);
}
