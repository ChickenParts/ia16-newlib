# Build IA-16 DOS Clang sysroots

The maintained build path is Ruby plus CMake and Ninja. It creates separate
compiler-rt builtins archives and DOS sysroots for every IA-16 frontend memory
model:

| Model | Code pointers | Data pointers | DOS image |
| --- | --- | --- | --- |
| tiny | near | near | COM |
| small | near | near | MZ |
| medium | far | near | MZ |
| compact | near | far | MZ |
| large | far | far | MZ |

Configure and build the LLVM compiler in its own build tree first. Then build
all five builtins archives into the compiler resource directory. `--clang`
must name the Clang from that build.

```sh
ruby compiler-rt/tools/build-ia16-builtins.rb \
  --source-root /path/to/llvm \
  --clang /path/to/llvm-build/bin/clang \
  --build-root /path/to/ia16-builtins-build \
  --install-prefix /path/to/llvm-build/lib/clang/24 \
  --jobs 4
```

The small-model archive keeps the historical
`lib/baremetal/libclang_rt.builtins-ia16.a` path. Tiny, medium, compact, and
large archives are installed below `lib/baremetal/<model>/`. Each model uses a
separate CMake build directory and a Ninja `builtins` target.

Build the Newlib and libgloss sysroots with the same compiler and resource
directory:

```sh
ruby libgloss/ia16/tools/build-clang-sysroot.rb \
  --source-root /path/to/ia16-newlib \
  --tool-root /path/to/llvm-build \
  --builtins-root /path/to/llvm-build/lib/clang/24 \
  --build-root /path/to/ia16-dos-build \
  --install-prefix /path/to/ia16-dos-install \
  --jobs 4
```

Both scripts retain command logs and a JSON manifest under the build root.
Configure creates the target-specific Newlib Makefile and headers; Ruby reads
its source lists, then generates a Ninja graph for the C, assembly, archive,
and install inputs. The scripts do not execute Make. Use fresh output roots for
independent toolchain revisions; rerunning Ninja in an existing profile keeps
incremental object outputs.

The installed sysroots are under
`ia16-pc-msdos/<model>`. The generated `profile.sh` provides a compiler and a
full DOS link command for each model:

```sh
. /path/to/ia16-dos-install/profile.sh
ia16_clang_tiny -c hello.c -o hello-tiny.o
ia16_link_tiny hello-tiny.o -o HELLO.COM
ia16_clang_medium -c hello.c -o hello-medium.o
ia16_link_medium hello-medium.o -o HELLO.EXE
```

The link functions use the model's startup object, linker script, Newlib
archives, libgloss archive, and matching compiler-rt builtins. Tiny keeps the
COM layout; the Clang small profile keeps the near/near MZ ABI. Clang MZ links
use LLD's native `--oformat=mz` writer so far code and data pointers receive
DOS loader relocation entries. The existing GCC linker scripts remain
unchanged.

Run the maintained acceptance harness after building the sysroots. It generates
a Ninja graph for each model, links the same object with both Clang and direct
`ld.lld`, and checks both guest receipts in DOSBox Staging's 386 CPU model using
SDL's offscreen video driver. Repeat with native, Full LTO, and Thin LTO objects:

```sh
ruby libgloss/ia16/tests/memory-models/run.rb \
  --profile /path/to/ia16-dos-install/profile.sh \
  --out /path/to/fresh-native-output --lto native
# Repeat with fresh output directories and --lto full / --lto thin.
```

The fixture checks startup arguments and environment, constructors/destructors,
volatile initialized and zero-initialized emulated TLS, allocation, setjmp and
longjmp, libm, strings, and DOS file/directory operations. Medium and large execute
direct and indirect calls across more than 64KB of live code. Compact and large
use more than 64KB of live static data, exercise buffers outside DS, and preserve
more than 64KB of simultaneous heap allocations. Link maps record the live code
and far-data sizes. Each lane records commands, hashes, receipts, and guest
process ownership. A lane's `STOP` file stops and reaps its owned guest if manual
intervention is needed; the harness imposes no execution deadline.

The emitted instruction set is 8086. The LLVM companion tools
`llvm/utils/ia16/installed-runtime/run.rb` and `run-8086-matrix.rb` qualify staged,
relocated installations and execute hashed images on an Intel 8086 PC1512 under
86Box. The DOSBox run alone does not establish the CPU floor. See those tools'
README for the required DOS media, ROMs, and image manifest format.

Near-data models share their 64KB data segment with the stack and heap. The MZ
profiles reserve the remaining DGROUP by default; an explicit `__stack_size`
linker definition can reduce that reservation. Compact and large release the
unused initial DOS allocation and acquire separate far-heap arenas. Individual
objects and functions must fit within one segment; the normal far allocator's
maximum user request is 65484 bytes, and aggregate allocation is limited by
available conventional DOS memory and an optional `_heaplen` limit. Arena order
is independent of DOS first-fit, best-fit, or last-fit allocation strategy.
`free` makes blocks reusable within the process; negative `_sbrk_r` requests fail
without moving its break. DOS releases the owned arenas when the process exits.
The separate `tests/far-heap/build.rb` suite checks all three allocation strategies,
the single-object boundary, failed growth, and preservation of live allocations.

The build uses generated target headers before generic Newlib headers and the
compiler's resource headers. It strips ambient include-path variables and
uses `-nostdinc`, so host headers cannot silently enter the target runtime.
Each model's manifest records source counts, archive/compiler hashes, selected
pointer widths, and commands. Build completion alone does not establish DOS
runtime compatibility; use the maintained memory-model acceptance tests and
the guest runtime suite for each installed profile.

The earlier `build-clang-sysroot.py` path only describes the historical
small-model setup. Do not use it to build or qualify medium, compact, or large
profiles.
