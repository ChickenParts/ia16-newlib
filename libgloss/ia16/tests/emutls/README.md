# DOS emulated TLS ABI test

Run with NASM and QEMU on PATH:

```
python3 libgloss/ia16/tests/emutls/run.py --tool-root /path/to/llvm-build --out /path/to/new-results
```

This compiles actual C `_Thread_local` objects with `-femulated-tls` and the
production `dos-emutls.c` helper. Tiny and small near-data models run at O0,
O2 and Oz. Every positive image boots twice to check fresh process state.
The checks cover initialized and zero storage, independent objects, stable
addresses after mutation and 64-byte alignment. Objects must contain no native
TLS sections or relocations. A deliberately incorrect initial-value expectation
and allocator failure are separate negative controls. Results and image hashes
are written to `results.json`; timeouts and unexpected exits fail the run.

The allocator is a deterministic test fixture that fills fresh storage with
nonzero bytes. This tests the compiler/helper ABI, not DOS malloc, CRT startup,
process teardown or emulator accuracy for an original 8086. QEMU executes the
real-mode code; compilation requests the 8086 instruction set.
