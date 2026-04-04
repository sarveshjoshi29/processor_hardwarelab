/**
 * code_muldiv.c
 * 
 * Comprehensive test for RV32M Multiply and Divide extensions.
 * Verifies MUL, DIV, and REM operations on the pipelined hardware.
 */

int main() {
    volatile int *result0 = (int *)0x100; // MUL
    volatile int *result1 = (int *)0x104; // DIV
    volatile int *result2 = (int *)0x108; // REM
    volatile int *result3 = (int *)0x10C; // MUL with negative
    volatile int *result4 = (int *)0x110; // DIV by zero catch (standard behavior)

    int a = 12;
    int b = 5;

    // 1. Multiplication: 12 * 5 = 60
    *result0 = a * b;

    // 2. Division: 12 / 5 = 2
    *result1 = a / b;

    // 3. Remainder: 12 % 5 = 2
    *result2 = a % b;

    // 4. Negative Multiplication: (-12) * 5 = -60
    int c = -12;
    *result3 = c * b;

    // 5. Large value multiplication
    int d = 1000;
    int e = 2000;
    volatile int *result5 = (int *)0x114;
    *result5 = d * e; // 2,000,000

    return 0;
}
