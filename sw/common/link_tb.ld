/* testbench memory: 256 KB at 0 (tb/axil_mem.v); stack at the top */
ENTRY(Reset_Handler)
MEMORY { RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 252K }
SECTIONS {
    .vectors : { KEEP(*(.vectors)) } > RAM
    .text : { *(.text*) *(.rodata*) } > RAM
    . = ALIGN(8);
    .data : { *(.data*) } > RAM
    .bss (NOLOAD) : { __bss_start = .; *(.bss*) *(COMMON) . = ALIGN(4); __bss_end = .; } > RAM
    __stack_top = 0x0003F000;
}
