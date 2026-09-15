# Real DOS CRT smoke test

Run against an installed Clang IA16 sysroot and the matching compiler builtins:

```
python3 libgloss/ia16/tests/dos-crt/run.py \
  --tool-root /path/to/llvm-build \
  --sysroot /path/to/install/ia16-pc-msdos \
  --dosbox-x /path/to/dosbox-x \
  --out /path/to/new-results-directory
```

The target include directory must retain generic newlib headers in
`include/newlib`, after the IA16 wrapper headers in `include`. Host headers
are excluded. The test generates the tiny linker script from this checkout,
links the installed DOS CRT and libraries, and runs the COM on DOSBox-X's
8086 CPU. It checks `puts` output, startup arguments, a static BSS array,
and the exact DOS exit status from `main`. A second executable prints the
same marker but returns 41, proving that stdout alone cannot pass the oracle.
Commands, tool output, and lane results are retained in the output directory.

The default is tiny-model COM. Use `--memory-model small` for the small-model
MZ CRT and linker script. Both run with normal linker overlap checks enabled.
The startup smoke does not establish BSS clearing when initial memory is nonzero;
heap and file-I/O checks are separate programs below.

Use `--program heap` to exercise the real DOS allocator: alignment, preserved
contents after growth, zeroed calloc, multiplication-overflow rejection,
512 allocate/free cycles, near-heap exhaustion and allocation after releasing
the exhausted heap. The same wrong-exit control runs for this program.
This coverage uses the installed allocator; it does not substitute a bump
allocator or establish interrupt reentrancy.

Use `--program abi` to verify that the assembly `strlen` preserves Clang's
callee-saved BX register while returning the correct length. It seeds BX
explicitly, so the check does not depend on the optimizer keeping a variable
in that register.

Use `--program services` for DOS file create/write/read/close/remove, missing
file `ENOENT`, inherited environment lookup and a basic positive `time()`
result. It checks these specific services; it does not claim comprehensive
DOS-error translation, text-mode newline conversion or time-zone correctness.
