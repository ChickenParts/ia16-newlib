# DOS far heap acceptance

Build against the ordinary generated Clang runtime profiles:

```sh
ruby libgloss/ia16/tests/far-heap/build.rb \
  --profile /path/to/install/profile.sh --tools /path/to/llvm-build \
  --out /mnt/build/llvm/far-heap-acceptance
```

Mount the output directory as a writable DOS drive and execute `RUN.BAT`.
Success produces `DONE.TXT`, nine `P0.TXT` through `P8.TXT` receipts containing
`PASS heap`, and no `.ERR` receipts. The COM parents select first-fit, best-fit,
and last-fit before loading each compact/large child's ordinary CRT, then
restore the original strategy and propagate the child's exit code.

Far cases hold three 30000-byte allocations simultaneously, preserve bytes
through a 50000-byte realloc, verify a 50000-byte calloc, reject oversized
allocation/reallocation and calloc overflow with `ENOMEM`, retain live bytes
after failures with a large free top chunk, verify a stable break after failed
shrink, and allocate/write/free a 65484-byte object. Near cases retain the
ordinary small allocation/realloc contract.

With 90000 bytes live, far cases also capture `malloc_stats` through ordinary
stdio and check all three byte totals against `mallinfo` without truncation.

The far heap reserves DOS blocks before serving growth and sorts their
selectors without changing DOS's allocation strategy. The first paragraph of
each block contains its pool link and extent. A full 64KB block leaves its last
paragraph unused so breaks and one-past chunk addresses never require offset
65536. Newlib grows in DOS paragraphs and counts supplied storage rather than
packed-selector gaps. Freed chunks remain reusable; DOS releases the blocks
owned by the process at exit. `_heaplen` continues to bound supplied growth.
