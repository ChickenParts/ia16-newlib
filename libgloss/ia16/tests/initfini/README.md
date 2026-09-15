# Clang DOS constructor and destructor acceptance

The Clang tiny/small real-mode cdecl CRT replaces GCC crtbegin/crtend's missing
callback walks. Existing fall-through `.preinit` code runs first, followed by
preinit-array entries, reverse legacy constructors, and forward init-array entries.
Finalization is registered with atexit before initialization. Normal return from
main and explicit exit therefore run application cleanup, reverse fini-array
entries, and forward legacy destructors before stdio cleanup. Legacy zero/-1
sentinels are skipped. Failure to register finalization terminates with status127.

Generate the matching linker script explicitly:

```
sh libgloss/ia16/dos-mt.ld.in -nostdlib -mclang-runtime
sh libgloss/ia16/dos-mx.ld.in -nostdlib -mclang-runtime
```

The libgloss Makefile supplies the equivalent `clang_runtime=yes` based on its
compiler feature probe. GCC remains the generator default. DPMI-capable and medium
scripts ignore this mode; their startup paths, DOSX and TSR CRT paths are excluded.
Do not pair the Clang CRT with a script lacking its callback boundary symbols.

Direct _exit bypasses application atexit/destructor callbacks. The runtime's timer
hook still needs releasing because DOS does not restore INT1Ch on termination.
The Clang near real-mode timer object adds a fall-through `.fini` call to its
existing idempotent destructor. Normal exit has already restored the vector; the
fallback then does nothing. It preserves the existing rule that a subsequently
installed third-party vector is not overwritten.

Run `python3 run.py --help` for required paths. The runner compiles isolated copies
and generates scripts with explicit Clang mode, using an existing DOS sysroot and
complete builtins archive. Source and installed artifacts are not modified. It
requires a new output directory and an IA16 LLD with the binary/MZ fixes.

Sixteen real DOSBox-X 8086 lanes cover tiny COM and small MZ, legacy lists and ELF
init/fini arrays, constructor priorities, atexit/destructor ordering, zero/-1
sentinels, argc/argv/envp, and main return versus exit versus direct _exit. The
actual near-data-segment `.preinit` object is linked, and its CS slot is checked
against DS and SS before any array or constructor. The actual timer constructor
is checked by invoking INT1Ch and observing times() advance; its destructor must
restore the captured vector.

For direct _exit, an independent DOS parent uses EXEC, checks the child's exact
exit status, then verifies the original timer vector. Only the direct-exit marker
may be printed by the child: application cleanup/destructors must not run.
Negative controls remove initialization (status70) or the timer fallback (the
parent rejects with status90 and restores the vector). Missing output, crashes,
unexpected callbacks or incorrect exit codes fail the runner. Results include
compiler, linker, archive and runtime-source hashes.

This is real-mode C runtime acceptance, not C++ ABI, DPMI, TSR or far-code support.
