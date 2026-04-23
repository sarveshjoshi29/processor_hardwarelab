OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
  imem (rx) : ORIGIN = 0x00000000, LENGTH = 4K
  /* We place DMEM at 0x40000000 so GCC knows it's a separate memory area.
     Our CPU's D-cache ignores the top 20 bits anyway! */
  dmem (rw) : ORIGIN = 0x40000000, LENGTH = 4K
}

SECTIONS
{
  .text : {
    *(.text.init)
    *(.text*)
  } > imem

  /* Data sections mapped to DMEM */
  .data : {
    . = ALIGN(4);
    _sdata = .;
    *(.rodata*)
    *(.data*)
    *(.sdata*)
    . = ALIGN(4);
    _edata = .;
  } > dmem

  .bss : {
    . = ALIGN(4);
    _sbss = .;
    *(.bss*)
    *(.sbss*)
    *(COMMON)
    . = ALIGN(4);
    _ebss = .;
  } > dmem

  /* ------------------------------------------------------------
     Stacks for both cores (grow downward)

     IMPORTANT: Keep stacks OUT of the .data/.bss region.
     We carve stack space from the top of DMEM so globals can grow
     upward from ORIGIN(dmem) without being overwritten.
  ------------------------------------------------------------ */
  __stack_size = 0x400; /* 1 KiB per core */

  _stack1 = ORIGIN(dmem) + LENGTH(dmem);
  __stack1_bottom = _stack1 - __stack_size;

  _stack0 = __stack1_bottom;
  __stack0_bottom = _stack0 - __stack_size;

  /* Fail the link if globals don't fit below the stacks. */
  ASSERT(_ebss <= __stack0_bottom, "DMEM overflow: .data/.bss overlap stacks")
}
