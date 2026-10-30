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

Run the maintained acceptance harness after building the sysroots. It compiles
one constructor, destructor, and indirect-call fixture per model, links each
binary with both Clang and direct `ld.lld`, and checks both guest receipts in
DOSBox Staging's 386 CPU model using SDL's offscreen video driver. The compiler
still emits the 8086 instruction set:

```sh
ruby libgloss/ia16/tests/memory-models/run.rb \
  --profile /path/to/ia16-dos-install/profile.sh \
  --out /path/to/fresh-acceptance-output
```

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
