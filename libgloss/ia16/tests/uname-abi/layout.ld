ENTRY(_start)
SECTIONS {
  .companions 0 (NOLOAD) : { KEEP(*(".*!" ".*&")) }
  .text 0 : AT(0) { *(.text.start .text.hook .text .text.* .fartext .fartext.*) }
  .data 0 : AT(ALIGN(SIZEOF(.text),16)) {
    *(.data .data.* .rodata .rodata.* .fardata .fardata.* .farrodata .farrodata.*)
  }
  .bss ALIGN(SIZEOF(.data),2) (NOLOAD) : AT(LOADADDR(.data)+ADDR(.bss)) {
    *(.bss .bss.* .farbss .farbss.*) *(COMMON)
  }
  .stack ALIGN(ADDR(.bss)+SIZEOF(.bss),16) (NOLOAD) : AT(LOADADDR(.data)+ADDR(.stack)) {
    . += 0x1000;
    __stack_end = .;
  }
}
