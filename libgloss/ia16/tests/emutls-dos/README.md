# DOS emulated TLS with the installed allocator

Run the fixture against a completed, immutable Clang DOS profile:

```
python3 run.py --profile INSTALL/profile.sh --tools PINNED_LLVM_ROOT \
  --dosbox /path/to/dosbox-x --out NEW_OUTPUT_DIRECTORY
```

The profile must provide `ia16_clang_tiny`, `ia16_link_tiny`, `ia16_clang_small`
and `ia16_link_small`. Their compiler options and installed libraries are used
unchanged; no replacement allocator or TLS helper is linked. The supplied tool
root should match the profile. The output directory must not already exist.

Four DOSBox-X 8086 lanes cover tiny COM and small MZ, each with a positive and a
wrong-template negative control. The C fixture uses compiler-generated emulated
TLS, checked in the object symbol table. It tests first-access zero filling,
nonzero template initialization, 16-byte alignment, distinct TLS objects, stable
addresses and preserved mutations across repeated accesses. Negative controls
must exit exactly70; positive cases must emit the success marker and exit42.

Before accessing TLS, the fixture fills and frees a real malloc allocation. It
reports whether TLS reused that poisoned storage. This strengthens the observed
zero-fill result when reuse occurs, without making a particular malloc placement
strategy a requirement. TLS allocations remain owned by the runtime until process
exit. The test models one execution thread and makes no scheduler or ISR allocator
reentrancy claim.

`commands.json` retains build/link commands and diagnostics; `results.json` records
profile/compiler/fixture hashes, exact guest output, exit checks, and poison reuse.
Missing output, a crash, wrong exit status, or unexpected output fails the runner.
No source files or installed profile artifacts are modified.
