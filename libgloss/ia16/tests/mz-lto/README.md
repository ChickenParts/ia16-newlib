# Small-model DOS MZ LTO fixture

`run.rb` is build-only. It uses Ninja to build native, FullLTO, and ThinLTO
small-model DOS programs against an explicit candidate LLVM tool root and the
matching frozen DOS runtime. Its generated `RUNALL.BAT` runs each program and
writes a DOS exit-status receipt. `run-guest.rb` launches that batch in
DOSBox-X `--silent` mode and checks the guest output and DOS exit receipts;
it keeps guest execution separate from compilation. The fixture checks that the CRT constructors
and destructors run, both emulated TLS variables retain their expected values
across translation units, newlib file I/O succeeds, and the unused cross-TU
function section is removed by FullLTO and ThinLTO.

For example:

```sh
ruby libgloss/ia16/tests/mz-lto/run.rb \
  --tool-root /path/to/candidate-llvm \
  --runtime-root /path/to/ia16-pc-msdos \
  --out /path/to/new-output
ruby libgloss/ia16/tests/mz-lto/run-guest.rb \
  --out /path/to/new-output --emulator /path/to/dosbox-x
```

The runtime script still checks that `main!` and `environ!` are absent. Its
`.text` wildcard excludes `!` and `&` companion sections so zero-sized ELF
metadata does not become DOS text. Startup, init, and exit fragments remain
`KEEP`ed because they fall through in linker-script order and have no direct
relocations for section garbage collection to follow.

This fixture qualifies the maintained `OUTPUT_FORMAT(binary)` consumer recipe
for compiler-generated near small-model inputs on 8086, with function/data
sections, `--gc-sections`, FullLTO, and ThinLTO. Unmatched companion sections
fall through to the script's existing `/DISCARD/` rule; the binary-script path
does not reject arbitrary positive-sized `!` or `&` companions. The separate
LLD MZ-writer test covers section-symbol `R_386_SEG16` origins and rejects
positive-sized companions under the true MZ writer's built-in checks. Neither
test claims support for arbitrary SEGELF inputs through the binary consumer
script. The LTO ABI-conflict test covers FullLTO only; mixed-model ThinLTO
diagnostics are outside this fixture's qualification.
