#!/usr/bin/env python3
"""Link the real DOS CRT/newlib and check stdout and DOS exit status."""
import argparse
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--tool-root', type=Path, required=True)
parser.add_argument('--sysroot', type=Path, required=True,
                    help='Target directory containing include/ and lib/')
parser.add_argument('--dosbox-x', type=Path, required=True)
parser.add_argument('--out', type=Path, required=True)
parser.add_argument('--program', choices=('main', 'heap', 'abi', 'services'), default='main')
parser.add_argument('--memory-model', choices=('tiny', 'small'), default='tiny')
args = parser.parse_args()
model_letter = 't' if args.memory_model == 'tiny' else 's'
executable = 'CRT.COM' if args.memory_model == 'tiny' else 'CRT.EXE'
root = Path(__file__).resolve().parents[2]
out = args.out.resolve()
out.mkdir(parents=True, exist_ok=False)
bin_dir = args.tool_root.resolve() / 'bin'
sysroot = args.sysroot.resolve()
commands = []


def run(command, env=None):
    command = [str(x) for x in command]
    result = subprocess.run(command, capture_output=True, text=True,
                            timeout=60, env=env)
    commands.append(dict(command=command, exit=result.returncode,
                         stdout=result.stdout, stderr=result.stderr))
    (out / 'commands.json').write_text(json.dumps(commands, indent=2))
    if result.returncode:
        raise RuntimeError(f'{command}: {result.stderr}')
    return result.stdout


resource = run([bin_dir / 'clang', '-print-resource-dir']).strip()
script = out / (args.memory_model + '.ld')
script.write_text(run(['sh', root / ('dos-mt.ld.in' if args.memory_model == 'tiny' else 'dos-mx.ld.in'), '-nostdlib']))
results = []
for name, returned, expected in [('positive', 42, b'EXIT42\r\n'),
                                 ('negative', 41, b'WRONGEXIT\r\n')]:
    lane = out / name
    lane.mkdir()
    run([bin_dir / 'clang', '--target=ia16-pc-msdos', '-march=8086',
         f'-mmemory-model={args.memory_model}', '-std=gnu23', '-Os', '-ffreestanding',
         '-fno-builtin', '-nostdinc', '-isystem', Path(resource) / 'include',
         '-isystem', sysroot / 'include', '-isystem', sysroot / 'include/newlib',
         f'-DRESULT={returned}', '-c', Path(__file__).with_name(args.program + '.c'),
         '-o', lane / 'main.o'])
    run([bin_dir / 'ld.lld', '-m', 'elf_ia16', '-T', script,
         '-L', sysroot / 'lib', sysroot / f'lib/dos-{model_letter}-c0.o', lane / 'main.o',
         '--start-group', '-lc', f'-ldos-{model_letter}', '-lm',
         args.tool_root.resolve() / 'lib/libclang_rt.builtins-ia16.a',
         '--end-group', '-o', lane / executable])
    (lane / 'CHECK.BAT').write_bytes(
        f'@echo off\r\nset IA16TEST=runtime\r\n{executable} > OUT.TXT\r\n'.encode() +
        b'if errorlevel 43 goto fail\r\nif not errorlevel 42 goto fail\r\n'
        b'echo EXIT42> STATUS.TXT\r\ngoto end\r\n:fail\r\n'
        b'echo WRONGEXIT> STATUS.TXT\r\n:end\r\n')
    config = lane / 'dosbox.conf'
    config.write_text('[cpu]\ncputype=8086\ncycles=fixed 3000\n')
    run([args.dosbox_x.resolve(), '-conf', config, '-nolog', '-noconsole',
         '-silent', '-exit', '-c', f'mount c "{lane}"', '-c', 'c:',
         '-c', 'CHECK.BAT', '-c', 'exit'],
        env=dict(os.environ, SDL_VIDEODRIVER='dummy', SDL_AUDIODRIVER='dummy'))
    stdout = (lane / 'OUT.TXT').read_bytes()
    status = (lane / 'STATUS.TXT').read_bytes()
    if stdout != b'IA16 DOS CRT PASS\n' or status != expected:
        raise RuntimeError(f'{name}: stdout={stdout!r}, status={status!r}')
    results.append(dict(lane=name, main_return=returned,
                        stdout=stdout.decode(), status=status.decode(), passed=True))
(out / 'results.json').write_text(json.dumps(results, indent=2))
print(json.dumps(dict(passed=len(results), results=str(out / 'results.json'))))
