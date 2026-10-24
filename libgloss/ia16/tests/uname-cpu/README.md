# DOS CPU classifier stack and segment regression

This fixture exercises `__ia16_get_hw_cpu` with `DS != SS`. It seeds the
classifier's stack-alias byte and `DS:0000`, then checks that the helper keeps
the original DS, restores the probed stack byte where it does not overlap an
earlier temporary push, and preserves IF and DF. It tests all sixteen entry-SP
residues modulo 16. For residues 9 and 10, the alias byte overlaps a word
written by the classifier's earlier `push AX` or `push SP`; the fixture checks
DS, flags, and return range there but does not assert the pre-call byte. The
classifier result must stay in the existing 8086, 80186, V20/V30, or
286-or-newer range.

The Ruby runner generates a small Ninja file and builds two COM images and
their helper objects: the pinned buggy source at
`f0add853331c830ecf0d14d107f6b51e4a0abb13` and the checked-out candidate.
It checks the generated 8086 object bytes: the baseline must overwrite the
computed segment and omit scratch restoration, while the candidate must save
FLAGS and DS before calculating the alias, decrement and restore the aliased
byte, and restore DS before FLAGS.
It also builds the protected-mode variant and verifies that it contains no
real-mode CLI or CPU probe sequence.

Run it with a published IA16 Clang handoff and a fresh output directory:

```sh
ruby run.rb \
  --tool-root /path/to/ia16-toolchain \
  --out /path/to/new-output
```

The COM program exits with status 0 when the checks pass and status 1 on the
first failed check. This runner does not launch an emulator. Hardware-profile
acceptance must run the generated candidate image on 8086, 80186, 286, NEC V20,
and NEC V30 lanes; it does not claim to detect later CPU generations more
precisely than the existing helper.
