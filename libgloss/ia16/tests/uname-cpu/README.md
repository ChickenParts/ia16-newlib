# DOS CPU classifier stack and segment regression

This fixture calls `__ia16_get_hw_cpu` with `DS != SS`. It records the helper's
raw AX result, checks the existing 0 through 3 class range, requires one class
to remain stable over all sixteen entry-SP residues, and checks DS, IF, DF, the
`DS:0000` sentinel, and the stack-alias byte. The stack marker is checked on
fourteen residues: for residues 9 and 10, the alias byte overlaps an earlier
`push AX` or `push SP`, so its value before the helper is not an appropriate
restore expectation. Those residues still run the class, DS, and flag checks.

The class values retain the helper's existing meaning: 0 is 8086, 1 is 80186,
2 is NEC V20/V30, and 3 is 286 or newer. The fixture does not change or extend
that classification policy.

Each image contains a stable CS-relative `IA24` receipt:

| Offset | Field | Initial value | Runtime value |
| ---: | --- | --- | --- |
| 0 | Magic | `IA24` | unchanged |
| 4 | Version | 1 | unchanged |
| 5 | Status | 0, pending | 1, pass; 2, fail |
| 6 | Case count | 16 | unchanged |
| 7 | Failure index | `0xff` | failed SP residue, or `0xff` on pass |
| 8 | Expected class | `0xffff` | first raw AX result |
| 10 | 16 observed class words | all `0xffff` | raw AX per SP residue, in order |

The DOS image prints `IA16-CPU-PASS-N` or `IA16-CPU-FAIL-N` (or `FAIL-X` if
the first class is outside 0 through 3) before exiting with DOS status 0 or 1.
It restores DS to CS and clears DF before using DOS output. The bare image
outputs AL to port `0xf4` (0 for pass, 1 for fail), then halts. Load the bare
binary at `CS:0100`; its entry VMA is 0x100. `results.json` records the receipt
and class-array VMAs reported by `llvm-nm` for all four images, along with
image hashes and receipt layout.

The Ruby runner generates a Ninja file and builds baseline and candidate DOS
COM images and bare binaries, plus a protected-mode object. It obtains the
buggy helper from pinned source revision
`f0add853331c830ecf0d14d107f6b51e4a0abb13`. Object checks confirm the baseline
overwrites its alias segment and does not restore the decremented byte; the
candidate saves/restores DS and FLAGS, normalizes DS to SS for both the NEC
XLAT and Intel stack probes, and restores the byte. The protected-mode object
must omit the real-mode CLI and CPU probe, and the bare fixture object must
contain `OUT 0xf4, AL` without DOS INT 21h.

Run with the published IA16 Clang handoff and a fresh output directory:

```sh
ruby run.rb \
  --tool-root /path/to/ia16-toolchain \
  --out /path/to/new-output
```

The Ruby runner builds through Ninja and does not launch an emulator. Hardware
acceptance should run the baseline and candidate images on Intel 8086/80186,
NEC V20/V30, and 286 profiles, checking the DOS marker or bare receipt and
confirming the exact class word in all sixteen slots.
