# DOS provider regressions

Build all five ordinary installed profiles with Ninja:

```sh
ruby libgloss/ia16/tests/dos-providers/build.rb \
  --profile /path/to/install/profile.sh --out /mnt/build/llvm/dos-provider-probes
```

Mount the output directory as a writable DOS drive and run `RUN.BAT`. Success
creates `DONE.TXT` and no `FAIL.TXT`. Each `A0.TXT` through `A4.TXT` contains
`abort () called`; the batch also checks each abort's exact DOS exit status 134.
The small/medium source puts its filename first in data, catching a valid object
at the near null-pointer address. The machine abort stub exercises its own code
bank's relocated DGROUP selector.

Each `C0.TXT` through `C4.TXT` contains `CX 0000` followed by `PASS create`.
The temporary INT 21h hook captures the complete create-attribute word and
rejects reserved high bits. The old CL-only provider gives `CX 0600` and fails.
The hook restores the original vector before reporting its result.

`images.json` records exact image hashes. The broader memory-model runtime
fixture covers arbitrary DS values, DBCS argument loads, getpid, duplication
error paths, and rename's independent DS/ES selectors.
