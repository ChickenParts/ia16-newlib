# Incremental IA-16 DOS runtime candidate

This helper replaces only the fixed `dos-uname-impl.o` member in the existing
small and tiny DOS archives. It verifies every member of the pinned f0add85
archives against its standalone object before making a Ninja graph. It then
compiles the committed source with the selected maintained Clang, rebuilds the
two archives from the verified baseline objects, and stages a fresh prefix.

The f0add85 source, build, and installed prefix are immutable inputs. The
candidate keeps the existing libc, startup objects, and header tree byte for
byte; the generated manifest records their hashes and the new object/archive
hashes. This is an incremental runtime candidate, not a full runtime rebuild or
a new header qualification. The install prefix must not exist before staging.

## Generate and stage

Choose the clean, committed runtime source checkout that contains the fix. It
must descend from f0add85 and modify `libgloss/ia16/dos-uname-impl.S`. Then run:

```sh
ruby libgloss/ia16/tools/rebuild-clang-cpu-classifier.rb \
  --source-root /mnt/build/ia16-dos-runtime-fixed-source \
  --baseline-build /mnt/build/ia16-dos-runtime-f0add85-build \
  --baseline-prefix /mnt/build/ia16-dos-runtime-f0add85 \
  --tool-root /mnt/build/llvm/handoffs/ia16-7c0a6c568bd6-flags-20261024 \
  --build-root /mnt/build/llvm/issue241-incremental-runtime-build \
  --install-prefix /mnt/build/ia16-dos-runtime-issue241-candidate

ninja -C /mnt/build/llvm/issue241-incremental-runtime-build stage-candidate
```

The generator records the exact compiler command and source revision in
`rebuild-plan.json`; Ninja owns compilation, archive rebuilding, and staging.
The current Clang resource directory and its queried builtins archive are used.
The old f0add85 toolchain is never used to compile the replacement object.

## Qualification seal

The staged manifest and build profile remain marked
`candidate-staged-qualification-pending`. After the external DOS runtime VM
acceptance completes, the acceptance owner may write
`vm-acceptance.json` in the build root with these matching fields:

```json
{
  "status": "pass",
  "source_commit": "<the source commit in rebuild-plan.json>",
  "install_prefix": "/mnt/build/ia16-dos-runtime-issue241-candidate",
  "candidate_manifest_sha256": "<SHA256 of candidate-manifest.json>"
}
```

Only then run `ninja -C <build-root> seal`. Sealing validates the receipt and
the candidate prefix tree hash, and writes `sealed.json` in the build root. It
does not rewrite the installed prefix. Do not mark the runtime accepted before
that external receipt is available.

The helper's isolated synthetic checks can be run with:

```sh
ruby libgloss/ia16/tests/clang-sysroot-incremental/test.rb
```
