#include "lib.h"

// ---------------------------------------------------------
// ATOMIC TRANSACTION TEST (DUAL CORE)
// - Updates shared state using LR/SC (no bank_lock)
// - Serial prints are protected with a mutex so output
//   from both cores won't interleave.
// ---------------------------------------------------------

typedef struct
{
    volatile int balance;
    volatile int deposits;
    volatile int withdrawals;
    volatile int done0;
    volatile int done1;
} shared_t;

static shared_t shared = {
    .balance = 1000,
    .deposits = 0,
    .withdrawals = 0,
    .done0 = 0,
    .done1 = 0,
};

static mutex_t uart_lock = {0};

static void safe_print_str(const char *s)
{
    mutex_lock(&uart_lock);
    print_str(s);
    mutex_unlock(&uart_lock);
}

static void safe_print_kv(const char *k, int v)
{
    mutex_lock(&uart_lock);
    print_str(k);
    print_int(v);
    print_str("\r\n");
    mutex_unlock(&uart_lock);
}

static void delay(volatile int loops)
{
    while (loops-- > 0)
    {
        __asm__ volatile("nop");
    }
}

// Atomic fetch-add using LR/SC.
static int atomic_fetch_add(volatile int *addr, int delta)
{
    int oldval;
    int newval;
    int result;
    __asm__ volatile(
        "1: \n\t"
        "lr.w %[old], (%[a])\n\t"
        "add %[new], %[old], %[d]\n\t"
        "sc.w %[res], %[new], (%[a])\n\t"
        "bnez %[res], 1b\n\t"
        : [old] "=&r"(oldval),
          [new] "=&r"(newval),
          [res] "=&r"(result)
        : [a] "r"(addr),
          [d] "r"(delta)
        : "memory");
    return oldval;
}

// ---------------------------------------------------------
// CORE 0: deposits (+10) N times
// ---------------------------------------------------------
int main(void)
{
    safe_print_str("[CORE 0] atomic transaction test start\r\n");

    const int n = 50;
    for (int i = 0; i < n; i++)
    {
        atomic_fetch_add(&shared.balance, +10);
        atomic_fetch_add(&shared.deposits, +1);

        if ((i % 10) == 0)
        {
            safe_print_kv("[CORE 0] deposits=", atomic_read(&shared.deposits));
        }

        delay(1500);
    }

    atomic_write(&shared.done0, 1);
    safe_print_str("[CORE 0] done\r\n");

    // Wait for core1 to finish, then print final summary.
    while (atomic_read(&shared.done1) == 0)
    {
        delay(5000);
    }

    mutex_lock(&uart_lock);
    print_str("\r\n[SYSTEM] FINAL SUMMARY\r\n");
    print_str("balance=");
    print_int(atomic_read(&shared.balance));
    print_str("\r\n");
    print_str("deposits=");
    print_int(atomic_read(&shared.deposits));
    print_str("\r\n");
    print_str("withdrawals=");
    print_int(atomic_read(&shared.withdrawals));
    print_str("\r\n");
    print_str("expected balance = 1000 + 50*10 - 40*5 = 1300\r\n");
    mutex_unlock(&uart_lock);

    for (;;)
    {
    }
}

// ---------------------------------------------------------
// CORE 1: withdrawals (-5) N times
// ---------------------------------------------------------
void core1_main(void)
{
    safe_print_str("[CORE 1] atomic transaction test start\r\n");

    const int n = 40;
    for (int i = 0; i < n; i++)
    {
        atomic_fetch_add(&shared.balance, -5);
        atomic_fetch_add(&shared.withdrawals, +1);

        if ((i % 10) == 0)
        {
            safe_print_kv("[CORE 1] withdrawals=", atomic_read(&shared.withdrawals));
        }

        delay(2500);
    }

    atomic_write(&shared.done1, 1);
    safe_print_str("[CORE 1] done\r\n");

    for (;;)
    {
    }
}
