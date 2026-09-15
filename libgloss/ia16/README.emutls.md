# DOS near-data emulated TLS

Clang programs using C `_Thread_local` must compile with `-femulated-tls` and
link the DOS runtime containing `dos-emutls.o`. The helper implements the
four-field LLVM/libgcc emulated TLS control ABI for tiny and small memory
models, with 16-bit near data pointers. Far-data models are not supported.

DOS supplies one C execution thread per process in this profile. Each TLS
object is allocated lazily, aligned, and initialized from its template or zero.
The allocation remains live until process exit. Invalid alignment, size overflow
or allocation failure calls `abort`. The helper does not provide scheduler
thread isolation or reentrant allocation from interrupt handlers.

The test in `tests/emutls` validates generated TLS accesses and the helper with
a controlled allocator. Full DOS startup, the production allocator and consumer
acceptance remain separate integration requirements; a passing ABI test alone
does not establish a complete supported sysroot.
