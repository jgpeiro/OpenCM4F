/* OpenCM4F SoC: code and constants in the 32 KB ROM, data / bss / stack in the 24 KB RAM */
ENTRY(Reset_Handler)
MEMORY {
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 32K
    RAM (rwx) : ORIGIN = 0x20000000, LENGTH = 24K
}
SECTIONS {
    .vectors : { KEEP(*(.vectors)) } > ROM
    .text : { *(.text*) *(.rodata*) . = ALIGN(4); } > ROM
    .ARM.exidx : { *(.ARM.exidx*) } > ROM
    .data : ALIGN(4) { __data_start = .; *(.data*) . = ALIGN(4); __data_end = .; } > RAM AT > ROM
    __data_load = LOADADDR(.data);
    /* CoreMark's static_memblk is a byte array that holds pointers and words: align it */
    .bss (NOLOAD) : ALIGN(8) { __bss_start = .; *(.bss.static_memblk) *(.bss*) *(COMMON) . = ALIGN(4); __bss_end = .; } > RAM
    __stack_top = ORIGIN(RAM) + LENGTH(RAM);
    __stack_size = __stack_top - __bss_end;
    ASSERT(__stack_size >= 4096, "less than 4 KB left for the stack")
}
