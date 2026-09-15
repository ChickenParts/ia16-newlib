# IA16 near setjmp and zero-argument BX acceptance

`run.py --help` lists the explicit source, compiler/resource, LLVM tools, DOS
sysroot, complete builtins archive, DOS linker script, emulator and output paths.
The output directory must not exist. The script leaves source trees and installed
libraries untouched, compiles isolated objects, and records commands and verdicts.

The real DOSBox-X 8086 runs check:

* C setjmp returns zero initially, longjmp(0) returns one, and longjmp(123) returns
  123, with guards surrounding the public 20-byte near jmp_buf;
* assembly-level preservation of BX, SI, DI, BP, SP and ES, with a second guarded
  buffer and deliberate register destruction before longjmp;
* BX preservation across the CPU-identification helper and the actual times
  constructor/destructor, each with a different register sentinel;
* O0, Os and Oz callers;
* negative controls for a wrong restored-register expectation, missing CPU-helper
  BX preservation, missing times-ctor preservation, and missing dtor preservation.

The tests expose the times routines' local symbols with assembler aliases and
remove their automatic constructor/destructor entries from the isolated object.
This lets the fixture invoke each routine exactly once, install/remove the real
DOS timer vector, and avoid a duplicate hook. Both expected success and rejection
paths check the exact DOS exit code; a crash or missing output fails the runner.

The public header also has a compile check for its 22-byte far-text layout. It
uses the same `__IA16_CMODEL_IS_FAR_TEXT` switch as setjmp.S. Clang currently emits
`__FAR_CODE__` for its medium model; a future supported medium newlib profile must
supply the matching compatibility macro throughout the runtime build. This test
does not establish far-text runtime acceptance.

The times assembly's DPMI branches receive matching BX pushes/pops, but only
real-mode execution is exercised here. DPMI-only assembly, including dx-tb.S,
requires its own calling-convention audit and protected-mode runtime acceptance;
this patch does not claim that work is complete.
