#!/usr/bin/env python3
"""Exercise the real Clang DOS startup, callbacks and exit path."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

p = argparse.ArgumentParser()
for name in ['source', 'clang', 'resources', 'ld', 'sysroot', 'builtins', 'dosbox', 'out']:
    p.add_argument('--' + name, type=Path, required=True)
a = p.parse_args()
fixture = Path(__file__).resolve().parent
out = a.out.resolve()
out.mkdir()
source = a.source / 'libgloss/ia16'
common = [a.clang, '--target=ia16-pc-msdos', '-march=8086', '-resource-dir', a.resources,
          '-Os', '-ffreestanding', '-fno-builtin', '-D__IA16_CALLCVT_CDECL',
          '-nostdinc', '-isystem', a.sysroot / 'include', '-isystem',
          a.sysroot / 'include/newlib', '-isystem', a.resources / 'include',
          '-I', source]

def run(cmd, **kw):
    kw.setdefault('timeout', 60)
    process = subprocess.run([str(x) for x in cmd], text=True, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, **kw)
    with (out / 'commands.log').open('a') as log:
        log.write(' '.join(str(x) for x in cmd) + '\n' + process.stdout + process.stderr)
    process.check_returncode()
    return process.stdout

cases = []
for model in ['tiny', 'small']:
    script = source / ('dos-mt.ld.in' if model == 'tiny' else 'dos-mx.ld.in')
    env = dict(os.environ, CC=str(a.clang), CFLAGS='--target=ia16-pc-msdos',
               clang_runtime='no')
    text = run(['sh', script, '-nostdlib', '-mclang-runtime'], env=env)
    ldscript = out / (model + '.ld')
    ldscript.write_text(text)
    for style in ['legacy', 'array']:
        for terminate in ['return', 'exit', 'direct']:
            name = model[0] + style[0] + terminate[0]
            cases.append((name.upper(), model, style, terminate, False, ldscript))
    cases.append((model[0].upper() + 'NEG', model, 'legacy', 'return', True, ldscript))
    cases.append((model[0].upper() + 'LEAK', model, 'legacy', 'direct', 'timer', ldscript))

for name, model, style, terminate, negative, ldscript in cases:
    lane = out / name
    lane.mkdir()
    cc = common + ['-mmemory-model=' + model]
    crt = (source / 'dos-models-crt0.S').read_text()
    if negative is True:
        old = '\tcallw\t.Lclang_init'
        assert crt.count(old) == 1
        crt = crt.replace(old, '\tnop', 1)
    (lane / 'crt.S').write_text(crt)
    run(cc + ['-D' + model.upper(), '-c', lane / 'crt.S', '-o', lane / 'crt.o'])
    flags = ['-fuse-init-array'] if style == 'array' else ['-fno-use-init-array']
    if terminate == 'exit':
        flags += ['-DEXPLICIT_EXIT']
    elif terminate == 'direct':
        flags += ['-DDIRECT_EXIT']
    run(cc + flags + ['-c', fixture / 'runtime.c', '-o', lane / 'runtime.o'])
    run(cc + ['-c', fixture / 'runtime.S', '-o', lane / 'capture.o'])
    # Link the maintained timer object directly so its real legacy ctor/dtor
    # are retained, without aliases or replacement implementations.
    times = (source / 'dos-timesr.S').read_text()
    if negative == 'timer':
        old = '\t.section .fini, "ax"\n\tcallw\t.Ldtor_timesr'
        assert times.count(old) == 1
        times = times.replace(old, '\t.section .fini, "ax"\n\tnop')
    (lane / 'times.S').write_text(times)
    run(cc + ['-c', lane / 'times.S', '-o', lane / 'times.o'])
    run(cc + ['-c', source / 'dos-near-data-segment.S', '-o', lane / 'near.o'])
    ext = '.COM' if model == 'tiny' else '.EXE'
    executable = ('C' + name if terminate == 'direct' else name) + ext
    run([a.ld, '-m', 'elf_ia16', '-T', ldscript, '-L', a.sysroot / 'lib',
         lane / 'crt.o', lane / 'runtime.o', lane / 'capture.o', lane / 'times.o', lane / 'near.o',
         '--start-group', '-lc', '-ldos-t' if model == 'tiny' else '-ldos-s',
         '-lm', a.builtins, '--end-group', '-o', out / executable])
    if terminate == 'direct':
        run(common + ['-mmemory-model=tiny', '-DCHILD_NAME="' + executable + '"',
                      '-c', fixture / 'parent.S', '-o', lane / 'parent.o'])
        run([a.ld, '-m', 'elf_ia16', '-T', fixture / 'parent.ld', lane / 'parent.o',
             '-o', out / (name + '.COM')])
        ext = '.COM'
    status = 90 if negative == 'timer' else (70 if negative else 42)
    (out / (name + '.BAT')).write_bytes((
        f'@echo off\r\n{name}{ext} x "two words" > {name}.OUT\r\n'
        f'if errorlevel {status+1} goto fail\r\n'
        f'if not errorlevel {status} goto fail\r\n'
        f'echo EXIT{status}> {name}.STA\r\ngoto end\r\n'
        f':fail\r\necho WRONGEXIT> {name}.STA\r\n:end\r\n').encode())

(out / 'dosbox.conf').write_text('[cpu]\ncputype=8086\ncycles=fixed 3000\n')
cmd = [str(a.dosbox), '-silent', '-conf', str(out / 'dosbox.conf'),
       '-c', f'mount c {out}', '-c', 'c:']
(out / 'ALL.BAT').write_bytes(('\r\n'.join(['@echo off'] + ['call ' + name + '.BAT' for name, *_ in cases]) + '\r\n').encode())
cmd += ['-c', 'ALL.BAT', '-c', 'exit']
with (out / 'dosbox.log').open('w') as log:
    subprocess.run(cmd, check=True, timeout=60, stdout=log, stderr=log,
                   env=dict(os.environ, SDL_VIDEODRIVER='dummy', SDL_AUDIODRIVER='dummy'))
expected = 'INIT AND TIMER PASS\nATEXIT PASS\nFINI PASS\nTIMER FINI PASS'
results = {}
for name, model, style, terminate, negative, _ in cases:
    output = (out / (name + '.OUT')).read_text().strip()
    status = (out / (name + '.STA')).read_text().strip()
    lane_expected = 'DIRECT EXIT\nPARENT TIMER RESTORED' if terminate == 'direct' else expected
    if negative == 'timer':
        lane_expected = 'DIRECT EXIT'
    elif negative:
        lane_expected = ''
    expected_status = 'EXIT90' if negative == 'timer' else ('EXIT70' if negative else 'EXIT42')
    results[name] = {'model': model, 'style': style, 'termination': terminate,
                     'negative': negative, 'output': output, 'status': status,
                     'ok': output == lane_expected and status == expected_status}
report = {'clang_sha256': hashlib.sha256(a.clang.read_bytes()).hexdigest(),
          'ld_sha256': hashlib.sha256(a.ld.read_bytes()).hexdigest(),
          'builtins_sha256': hashlib.sha256(a.builtins.read_bytes()).hexdigest(),
          'source_sha256': {name: hashlib.sha256((source / name).read_bytes()).hexdigest()
                            for name in ['dos-models-crt0.S', 'dos-timesr.S',
                                         'dos-near-data-segment.S', 'dos-mt.ld.in', 'dos-mx.ld.in']},
          'results': results}
(out / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
assert all(r['ok'] for r in results.values())
