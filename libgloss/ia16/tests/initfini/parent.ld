OUTPUT_FORMAT(binary)
ENTRY(_start)
SECTIONS {
 . = 0x100;
 .text : { *(.text*) }
 .data : { *(.data*) }
 /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
