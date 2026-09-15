# DOS near-data-segment startup regression

The Clang near-text real-DOS path initializes its CS-resident segment slot in
`.preinit`, after startupE establishes DS == SS and before `.init` or main.
The instruction changes neither general registers nor FLAGS. GNU SEGELF/OZ
relocations and the existing DOSX constructor path remain unchanged; Clang
far-text real-DOS builds are rejected rather than given a near-only assumption.

The independent `.preinit.check` fragment compares the slot against both DS and
SS before main. The positive COM and MZ programs print NEAR SEGMENT PASS and
exit 42. A replacement object with a zero slot and no initializer must exit 43
without printing the marker. The test uses real startup objects and DOSBox-X.

```sh
python3 run.py --tool-root /path/to/tools --sysroot /path/to/ia16-pc-msdos \
  --header-stage /path/to/staged-headers --builtins /path/to/builtins.a \
  --dosbox /path/to/dosbox-x --out /path/to/new-results
```

`.preinit` is fall-through startup code, not a constructor-table entry. The
original explicit Clang CRT profile did not walk legacy `.ctors` or modern
`.init_array`; putting this initialization only in `.ctors.65535` would not
execute it. General constructor/destructor support is a separate startup
requirement, including the timer installation in dos-timesr.S. This test proves
the slot is ready before that machinery; it does not claim that all constructor
or timer behavior is implemented.

The maintained Clang profile now supplies those callback walks; see
[constructor and timer acceptance](../initfini/README.md) for their separate tests.
