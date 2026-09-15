#!/usr/bin/env python3
"""Validate compiler-generated emulated TLS against a real DOS malloc runtime."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--profile', type=Path, required=True,
                    help='Installed profile.sh providing ia16_clang/link_tiny/small')
parser.add_argument('--tools', type=Path, required=True,
                    help='Pinned LLVM tool root containing bin/llvm-nm and bin/clang')
parser.add_argument('--dosbox', type=Path, required=True)
parser.add_argument('--out', type=Path, required=True,
                    help='New output directory; existing paths are rejected')
args = parser.parse_args()
profile = args.profile.resolve()
tools = args.tools.resolve()
out = args.out.resolve()
out.mkdir()
source = Path(__file__).resolve().with_name('tls.c')
commands = []


def run(command):
    command = [str(x) for x in command]
    result = subprocess.run(command, capture_output=True, text=True, timeout=60)
    commands.append(dict(command=command, exit=result.returncode,
                         stdout=result.stdout, stderr=result.stderr))
    (out / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
    if result.returncode:
        raise RuntimeError(f'{command}: {result.stderr}')
    return result.stdout


cases = []
for model in ['tiny', 'small']:
    for negative in [False, True]:
        name = model[0].upper() + ('NEG' if negative else 'TLS')
        extension = '.COM' if model == 'tiny' else '.EXE'
        extra = ['-DNEGATIVE'] if negative else []
        # All paths and caller arguments are positional shell arguments. Only
        # these fixed, enumerated profile function names enter shell source.
        run(['bash', '-c', 'source "$1"; shift; ia16_clang_' + model + ' "$@"',
             'bash', profile, *extra, '-c', source, '-o', out / (name + '.o')])
        run(['bash', '-c', 'source "$1"; shift; ia16_link_' + model + ' "$@"',
             'bash', profile, out / (name + '.o'), '-o', out / (name + extension)])
        symbols = run([tools / 'bin/llvm-nm', out / (name + '.o')])
        if '__emutls_get_address' not in symbols or '__emutls_v.' not in symbols:
            raise RuntimeError('Object did not use compiler-generated emulated TLS')
        code = 70 if negative else 42
        (out / (name + '.BAT')).write_bytes((
            f'@echo off\r\n{name}{extension} > {name}.OUT\r\n'
            f'if errorlevel {code + 1} goto fail\r\n'
            f'if not errorlevel {code} goto fail\r\n'
            f'echo EXIT{code}> {name}.STA\r\ngoto end\r\n'
            f':fail\r\necho WRONGEXIT> {name}.STA\r\n:end\r\n').encode())
        cases.append((name, model, negative, code))

(out / 'dosbox.conf').write_text('[cpu]\ncputype=8086\ncycles=fixed 3000\n')
(out / 'ALL.BAT').write_bytes(('\r\n'.join(
    ['@echo off'] + ['call ' + name + '.BAT' for name, *_ in cases]) + '\r\n').encode())
with (out / 'dosbox.log').open('w') as log:
    subprocess.run([str(args.dosbox), '-silent', '-conf', str(out / 'dosbox.conf'),
                    '-c', f'mount c "{out}"', '-c', 'c:', '-c', 'ALL.BAT', '-c', 'exit'],
                   env=dict(os.environ, SDL_VIDEODRIVER='dummy', SDL_AUDIODRIVER='dummy'),
                   stdout=log, stderr=log, check=True, timeout=60)

results = {}
for name, model, negative, code in cases:
    output = (out / (name + '.OUT')).read_text().strip()
    status = (out / (name + '.STA')).read_text().strip()
    expected = {''} if negative else {
        'DOS REAL TLS PASS', 'DOS REAL TLS PASS\nPOISONED HEAP REUSED'}
    results[name] = dict(model=model, negative=negative, output=output, status=status,
                         poisoned_heap_reused='POISONED HEAP REUSED' in output,
                         ok=output in expected and status == f'EXIT{code}')
report = dict(profile=str(profile),
              profile_sha256=hashlib.sha256(profile.read_bytes()).hexdigest(),
              clang_sha256=hashlib.sha256((tools / 'bin/clang').read_bytes()).hexdigest(),
              fixture_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
              results=results)
(out / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
if not all(result['ok'] for result in results.values()):
    raise SystemExit(1)
