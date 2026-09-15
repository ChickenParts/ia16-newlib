# Rebuild the IA16 DOS Clang sysroot

`tools/build-clang-sysroot.py` builds the near-pointer DOS runtime in fresh
build/install directories. It supports tiny COM and small MZ consumers. It
uses the checked-in configure scripts; Autoconf regeneration is not required.
The input compiler must include the IA16 fixed-register, far-pointer macro,
DOS predefined macro, segment-to-segment copy lowering, and binary linker
LMA/segmented MEMORY fixes. Supply the complete IA16
compiler-rt builtins archive separately; its exact hash is recorded.

```sh
python3 libgloss/ia16/tools/build-clang-sysroot.py \
  --source-root /path/to/ia16-newlib \
  --tool-root /path/to/metachicken-build \
  --build-root /path/to/new-build \
  --install-prefix /path/to/new-install \
  --builtins /path/to/libclang_rt.builtins-ia16.a \
  --jobs 4
```

Build and install paths must not exist. Paths must not contain whitespace or
shell/Make metacharacters because Autoconf embeds them in Make commands. The
source and compiler trees are inputs and are not changed. Failures retain
all logs and partial outputs; choose fresh directories for another attempt.

The library is compiled as GNU17, for 8086 with the small memory model,
`-Os`, and emulated TLS. Its near-pointer C ABI is also used by tiny callers;
the two formats select their matching startup object and libdos archive.
The compiler must define `__MSDOS__` for the selected DOS target; the profile
does not substitute a user macro for that target contract.
Consumer functions select GNU23 and an explicit tiny or small model.

The build puts generated `newlib/targ-include` before generic newlib headers
using explicit compiler `-I` options and matching ordered `-isystem`
entries. The duplicated system entries are intentional: the top-level Make
rules append `-isystem` for the same directories, which makes Clang promote
earlier `-I` entries into the system-header search order. Listing newlib
explicitly before the resource headers preserves `limits.h` in that case. This matters because libgloss inserts
its own generic `-I` options before ordinary `-isystem` directories. Header
autodetection is constrained with `libc_cv_compiler_isystem` to Clang's
resource directory. `-nostdinc` and removal of ambient compiler include
variables prevent accidental host-header discovery. The installed generic
headers are preserved under `include/newlib` for target `include_next`
wrappers, and the existing header oracle validates both tiers.

`build-profile.json` records source revision/status, compiler/linker/builtins
hashes, commands, return codes, archive hashes, and the complete header
trace. Separate logs retain configure, make, install, and header checks.
A successful build and header check do not substitute for DOS runtime tests.

Compile and link a consumer with the generated shell functions:

```sh
. /path/to/new-install/profile.sh
ia16_clang_tiny -c hello.c -o hello.o
ia16_link_tiny hello.o -o HELLO.COM
ia16_clang_small -c hello.c -o hello-small.o
ia16_link_small hello-small.o -o HELLO.EXE
```

The link functions use the actual DOS CRT and newlib plus the supplied
compiler-rt archive. They retain normal linker section checks. The generated
scripts omit GCC startup/default libraries so these are never selected from
the host. The tiny/small profile does not claim DOS extender support, far
memory allocation, or multithreaded TLS semantics.
