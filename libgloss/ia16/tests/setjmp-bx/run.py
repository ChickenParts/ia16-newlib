#!/usr/bin/env python3
"""Run the IA16 near setjmp ABI and zero-argument BX regression in DOSBox-X."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

p = argparse.ArgumentParser()
p.add_argument('--source', type=Path, required=True)
p.add_argument('--clang', type=Path, required=True)
p.add_argument('--resources', type=Path, required=True)
p.add_argument('--tools', type=Path, required=True)
p.add_argument('--sysroot', type=Path, required=True)
p.add_argument('--builtins', type=Path, required=True)
p.add_argument('--dos-link-script', type=Path, required=True)
p.add_argument('--dosbox', type=Path, required=True)
p.add_argument('--out', type=Path, required=True)
a = p.parse_args()
fixture = Path(__file__).resolve().parent
out = a.out.resolve()
out.mkdir()
include = out / 'include/machine'
include.mkdir(parents=True)
(include / 'setjmp.h').write_bytes((a.source / 'newlib/libc/include/machine/setjmp.h').read_bytes())
libgloss = a.source / 'libgloss/ia16'
cc = [a.clang, '--target=ia16-pc-msdos', '-march=8086', '-mmemory-model=tiny',
      '-resource-dir', a.resources, '-ffreestanding', '-fno-builtin', '-nostdinc',
      '-D__IA16_CALLCVT_CDECL', '-isystem', out / 'include', '-isystem',
      a.sysroot / 'include', '-isystem', a.sysroot / 'include/newlib',
      '-isystem', a.resources / 'include', '-I', libgloss]

def run(cmd):
    process = subprocess.run([str(x) for x in cmd], text=True, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT)
    with (out / 'build.log').open('a') as log:
        log.write(' '.join(str(x) for x in cmd) + '\n' + process.stdout)
    process.check_returncode()

# The assembly's far layout is selected by this GCC-compatible ABI macro.
(out / 'far-header.c').write_text('#include <setjmp.h>\n_Static_assert(sizeof(jmp_buf)==22,"far text ABI");\n')
run(cc + ['-D__IA16_CMODEL_IS_FAR_TEXT', '-fsyntax-only', out / 'far-header.c'])

# Remove only the candidate's explicit Clang BX preservation for negative controls.
def without_bx(text):
    for op in ('pushw', 'popw'):
        text = text.replace('#ifdef __clang__\n\t' + op + '\t%bx\n#endif\n', '')
    return text

cases = [('O0', '-O0', None, 42), ('OS', '-Os', None, 42),
         ('OZ', '-Oz', None, 42), ('BADREG', '-Os', 'register', 84),
         ('BADCPU', '-Os', 'uname', 85), ('BADTIME', '-Os', 'times', 85),
         ('BADDTOR', '-Os', 'dtor', 85)]
for name, opt, mutation, status in cases:
    lane = out / name
    lane.mkdir()
    run(cc + [opt, '-c', fixture / 'jump.c', '-o', lane / 'jump.o'])
    extra = ['-DWRONG_REGISTER'] if mutation == 'register' else []
    run(cc + extra + ['-c', fixture / 'checks.S', '-o', lane / 'checks.o'])
    run(cc + ['-c', a.source / 'newlib/libc/machine/ia16/setjmp.S', '-o', lane / 'setjmp.o'])
    uname = (libgloss / 'dos-uname-impl.S').read_text()
    if mutation == 'uname':
        uname = without_bx(uname)
    (lane / 'uname.S').write_text(uname)
    run(cc + ['-c', lane / 'uname.S', '-o', lane / 'uname.o'])
    times = (libgloss / 'dos-timesr.S').read_text()
    if mutation == 'times':
        times = without_bx(times)
    # Expose existing local functions without modifying their instructions. Remove
    # automatic startup entries so calling the ctor cannot install its ISR twice.
    if mutation == 'dtor':
        ctor, dtor = times.split('.Ldtor_timesr:', 1)
        times = ctor + '.Ldtor_timesr:' + without_bx(dtor)
    times += '\n.global test_ctor,test_dtor\n.set test_ctor,.Lctor_timesr\n.set test_dtor,.Ldtor_timesr\n'
    (lane / 'times.S').write_text(times)
    run(cc + ['-c', lane / 'times.S', '-o', lane / 'times-ctors.o'])
    run([a.tools / 'bin/llvm-objcopy', '--remove-section=.ctors.65535',
         '--remove-section=.dtors.65535', lane / 'times-ctors.o', lane / 'times.o'])
    run([a.tools / 'bin/ld.lld', '-m', 'elf_ia16', '-T', a.dos_link_script,
         '-L', a.sysroot / 'lib', a.sysroot / 'lib/dos-t-c0.o', lane / 'jump.o',
         lane / 'checks.o', lane / 'setjmp.o', lane / 'uname.o', lane / 'times.o',
         '--start-group', '-lc', '-ldos-t', '-lm', a.builtins, '--end-group',
         '-o', out / (name + '.COM')])
    (out / (name + '.BAT')).write_bytes((
        f'@echo off\r\n{name}.COM > {name}.OUT\r\n'
        f'if errorlevel {status + 1} goto fail\r\n'
        f'if not errorlevel {status} goto fail\r\n'
        f'echo EXIT{status}> {name}.STA\r\ngoto end\r\n'
        f':fail\r\necho WRONGEXIT> {name}.STA\r\n:end\r\n').encode())
(out / 'dosbox.conf').write_text('[cpu]\ncputype=8086\ncycles=fixed 3000\n')
cmd = [str(a.dosbox), '-silent', '-conf', str(out / 'dosbox.conf'),
       '-c', f'mount c {out}', '-c', 'c:']
for name, *_ in cases:
    cmd += ['-c', 'call ' + name + '.BAT']
cmd += ['-c', 'exit']
with (out / 'dosbox.log').open('w') as log:
    subprocess.run(cmd, check=True, timeout=60, stdout=log, stderr=log,
                   env=dict(os.environ, SDL_VIDEODRIVER='dummy', SDL_AUDIODRIVER='dummy'))
results = {}
for name, _, mutation, status in cases:
    text = (out / (name + '.OUT')).read_text().strip()
    actual = (out / (name + '.STA')).read_text().strip()
    expected = 'SETJMP AND BX PASS' if mutation is None else ''
    results[name] = {'output': text, 'status': actual,
                     'ok': text == expected and actual == f'EXIT{status}'}
report = {'clang_sha256': hashlib.sha256(a.clang.read_bytes()).hexdigest(),
          'results': results, 'far_header_layout_compile': 'pass'}
(out / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
assert all(r['ok'] for r in results.values())
