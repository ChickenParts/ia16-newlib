# Kernel-version extension ABI

```sh
ruby libgloss/ia16/tests/uname-abi/build.rb --tool-root /path/to/llvm \
  --runtime-prefix /path/to/runtime --out /mnt/build/llvm/uname-abi-build
ruby libgloss/ia16/tests/uname-abi/run.rb \
  --build-dir /mnt/build/llvm/uname-abi-build --out /mnt/build/llvm/uname-abi-guest
```

The Ninja graph compiles maintained uname providers and separate callers for
all five models. These isolated ABI probes use MZ containers, including tiny;
normal COM startup has separate acceptance coverage.

The assembly fixture temporarily hooks INT21 AX=33FFh, returning a known
CS:offset string while preserving the real DOS handler for every other call.
This forces the successful extension path even when DOS does not implement it.
The caller checks full/truncated strings, minimum buffer rejection and guards,
then restores the handler. All five probes fail before repair and pass after.

Clang ignores GNU regparmcall and passes the selected C pointer/size_t ABI;
the old assembly helper reads AX/DX. The repair uses a Clang C provider and
preserves GNU assembly and all hardware-classifier instruction bytes.

The runner is headless DOSBox 386 with no execution timeouts. Its exact-image
manifest also works with LLVM installed-runtime/run-8086-matrix.rb for a true
8086 floor check. DOS output and exit status are checked independently.
