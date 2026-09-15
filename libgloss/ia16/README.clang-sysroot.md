# Explicit IA16 Clang header profile

The installed IA16 newlib tree has two kinds of headers at the same relative
paths.  Target files such as `sys/config.h` and `machine/ieeefp.h` add IA16
definitions and then use `#include_next` to reach their generic newlib
counterparts.  A flat install therefore cannot be used as a `-nostdinc`
sysroot by itself: the target file shadows the generic file that it needs.

`tools/stage-clang-sysroot.py` makes the required layout from a completed
newlib build and install.  It reads the inputs and creates a new output
directory with this include order:

1. `include/overlay` — `newlib/targ-include` from the completed IA16 build.
2. `include/generic` — the generic tree from `newlib/libc/include` in the
   source checkout.  This avoids depending on an optional `include/newlib`
   mirror in the flat install.

The generated `profile.sh` contains all compiler flags.  It names the
compiler resource headers explicitly and uses `-nostdinc`; no host include
directory is added.

## Usage

Run the script with a new output directory.  The output directory is refused
if it already exists, and none of the source, build, or install inputs are
modified.

```sh
python3 libgloss/ia16/tools/stage-clang-sysroot.py \
  --source-root /path/to/ia16-newlib \
  --tool-root /path/to/metachicken-build \
  --build-root /path/to/completed-newlib-build \
  --install-prefix /path/to/newlib-install \
  --target ia16-pc-msdos \
  --output /tmp/ia16-clang-header-stage
```

The script copies the two header tiers, writes `profile.sh`, and runs the
checked-in `tests/clang-sysroot/headers.c` oracle.  The oracle is compiled as
GNU23 with the IA16 small memory model and checks `stdio.h`, `stdlib.h`,
`errno.h`, `time.h`, `stdint.h`, the two `#include_next` overlays, and these
ABI facts: `int` is 16 bits, `long` is 32 bits, `size_t` is 16 bits, and this
port's `time_t` is 64 bits.  It also checks the IA16 integer limits and
little-endian floating-point macro.  `results.json` records the command,
compiler hash, copied file hashes, include trace, and any include path that
escaped the resource/overlay/generic roots.  `header-oracle.log` retains the
compiler output.

A passing result proves header staging and preprocessing/type checking only.
It does not prove that a program links, starts under DOS, implements the
libgloss system calls, or exercises malloc, TLS, or other runtime facilities.
Those acceptance gates require separate link and emulated-runtime fixtures.

After a successful stage, an equivalent explicit compile is:

```sh
. /tmp/ia16-clang-header-stage/profile.sh
ia16_clang_header -fsyntax-only "$IA16_HEADER_ORACLE"
```

`ia16_clang_header` is a shell function so each option remains a separate
argument even in shells that disable unquoted word splitting.  The profile
also exports `IA16_HEADER_CFLAGS` as a human-readable copy of the same flags.
The machine-readable result from the staging script remains the acceptance
record.
