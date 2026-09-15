# Near-data segment relocation

Run `python3 libgloss/ia16/tests/segment/run.py --tool-root /path/to/llvm --out /new/results`.

The test compiles the production assembly in tiny/small models and links it
with data at three different paragraph-aligned addresses. It checks the actual
segment word against the data address divided by 16, including an address near
the 16-bit offset limit. Logs retain every command and linker diagnostic.
This checks ELF relocation semantics; it does not validate DOS MZ loading.
