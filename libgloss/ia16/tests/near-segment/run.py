#!/usr/bin/env python3
"""Check loaded DS/SS initialization before main, for DOS COM and MZ."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

p = argparse.ArgumentParser()
p.add_argument('--tool-root', type=Path, required=True)
p.add_argument('--sysroot', type=Path, required=True)
p.add_argument('--header-stage', type=Path, required=True)
p.add_argument('--builtins', type=Path, required=True)
p.add_argument('--dosbox', required=True)
p.add_argument('--out', type=Path, required=True)
a = p.parse_args()
a.out = a.out.resolve()
a.out.mkdir(parents=True, exist_ok=False)
source = Path(__file__).resolve().parents[2]
fixture = Path(__file__).resolve().parent
commands = []
results = []

def run(cmd, **kwargs):
    cmd = [str(x) for x in cmd]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=60, **kwargs)
    commands.append({'command': cmd, 'exit': r.returncode, 'stdout': r.stdout, 'stderr': r.stderr})
    (a.out / 'commands.json').write_text(json.dumps(commands, indent=2))
    if r.returncode:
        raise RuntimeError(r.stderr or r.stdout)
    return r.stdout

resource = Path(run([a.tool_root / 'bin/clang', '-print-resource-dir']).strip())

for model, suffix, letter in [('tiny', 'COM', 't'), ('small', 'EXE', 's')]:
    d = a.out / model
    d.mkdir()
    script = d / 'runtime.ld'
    template = source / ('dos-mt.ld.in' if model == 'tiny' else 'dos-mx.ld.in')
    script.write_text(run(['sh', template, '-nostdlib']))
    flags = ['--target=ia16-pc-msdos', '-march=8086', '-mmemory-model=' + model,
             '-D__IA16_CALLCVT_CDECL=1']
    headers = ['-nostdinc', '-isystem', a.header_stage / 'include/overlay',
               '-isystem', a.header_stage / 'include/generic',
               '-isystem', resource / 'include']
    for name, path in [('positive', source / 'dos-near-data-segment.S'),
                       ('negative', fixture / 'negative.S'), ('check', fixture / 'check.S')]:
        run([a.tool_root / 'bin/clang', *flags, '-c', path, '-o', d / (name + '.o')])
    run([a.tool_root / 'bin/clang', *flags, *headers, '-Os', '-std=gnu23', '-c',
         fixture / 'main.c', '-o', d / 'main.o'])
    for lane, expected in [('positive', 'EXIT42'), ('negative', 'EXIT43')]:
        case = d / lane
        case.mkdir()
        exe = case / ('CRT.' + suffix)
        run([a.tool_root / 'bin/ld.lld', '-m', 'elf_ia16', '-T', script,
             '-L', a.sysroot / 'lib', a.sysroot / ('lib/dos-' + letter + '-c0.o'),
             d / (lane + '.o'), d / 'check.o', d / 'main.o', '--start-group',
             '-lc', '-ldos-' + letter, '-lm', a.builtins, '--end-group', '-o', exe])
        batch = ['@echo off', exe.name + ' > OUT.TXT', 'if errorlevel 44 goto fail',
                 'if errorlevel 43 goto negative', 'if not errorlevel 42 goto fail',
                 'echo EXIT42> STATUS.TXT', 'goto end', ':negative',
                 'echo EXIT43> STATUS.TXT', 'goto end', ':fail',
                 'echo WRONG> STATUS.TXT', ':end']
        (case / 'CHECK.BAT').write_bytes(('\r\n'.join(batch) + '\r\n').encode('ascii'))
        (case / 'dosbox.conf').write_text('[cpu]\ncputype=8086\ncycles=fixed 3000\n')
        run([a.dosbox, '-silent', '-conf', case / 'dosbox.conf', '-c',
             'mount c "' + str(case) + '"', '-c', 'c:', '-c', 'CHECK.BAT', '-c', 'exit'],
            env=dict(os.environ, SDL_VIDEODRIVER='dummy', SDL_AUDIODRIVER='dummy'))
        status = (case / 'STATUS.TXT').read_text().strip()
        output = (case / 'OUT.TXT').read_text().strip()
        results.append({'model': model, 'lane': lane, 'status': status, 'output': output,
                        'sha256': hashlib.sha256(exe.read_bytes()).hexdigest(),
                        'passed': status == expected and
                        output == ('NEAR SEGMENT PASS' if lane == 'positive' else '')})
(a.out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
print(json.dumps(results, indent=2))
raise SystemExit(0 if all(r['passed'] for r in results) else 1)
