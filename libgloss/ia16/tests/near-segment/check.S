/* Independent pre-main oracle: the runtime slot must contain both DS and SS. */
.code16
.section .preinit.check,"ax"
pushw %ax
movw %ss, %ax
cmpw %cs:__ia16_near_data_segment, %ax
jne 1f
movw %ds, %ax
cmpw %cs:__ia16_near_data_segment, %ax
jne 1f
movw $1, %ss:near_segment_ready
1:
popw %ax
