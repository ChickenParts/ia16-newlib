OUTPUT_FORMAT(elf32-i386)
ENTRY(_start)
SECTIONS {
 .aux_bang 0 (NOLOAD) : { *(".*!") }
 .aux_amp 0 (NOLOAD) : { *(".*&") }
 . = 0;
 .text : { *(.start) *(.text*) }
 .rodata : { *(.rodata*) }
 .data : { *(.data*) }
 .bss (NOLOAD) : { *(.bss*) *(COMMON) }
 /DISCARD/ : { *(.eh_frame*) *(.comment*) *(.note*) }
 ASSERT(. < 0xf000, "runtime overlaps stack")
}
