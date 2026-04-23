.section .text.init
.global _start
_start:
    # ----------------------------------------------------
    # CORE 0 RESET (Address 0x000)
    # ----------------------------------------------------
    # Setup UART base for safety
    lui s0, 0x20000

    # NOTE: .bss is already zeroed by the image generator (dmem.hex).
    # Clearing .bss here via cached stores can leave dirty D-cache lines
    # that later write back and clobber lock variables used via LR/SC.
    la sp, _stack0      # Set Core 0 stack
    call main           # Jump to Core 0 main
3:  j 3b                # Halt

    # ----------------------------------------------------
    # Spacer to align Core 1 code perfectly to 0x200 (byte 512)
    # ----------------------------------------------------
    .org 0x200
.global _start_core1
_start_core1:
    # ----------------------------------------------------
    # CORE 1 RESET (Address 0x200)
    # ----------------------------------------------------
    lui s0, 0x20000
    la sp, _stack1      # Set Core 1 stack
    call core1_main     # Jump to Core 1 main
4:  j 4b                # Halt
