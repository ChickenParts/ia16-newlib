/* Deliberately uninitialized slot. The pre-main oracle must reject it. */
.code16
.text
.globl __ia16_near_data_segment
__ia16_near_data_segment:
.short 0
