ENTRY(_start)
SECTIONS { .text 0x100 : { *(.text) } }
ASSERT(SIZEOF(.text) <= 0x200, "DOS parent must leave 256 bytes of stack")
