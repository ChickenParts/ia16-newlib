#!/usr/bin/env python3
"""Check the DOS near-data segment relocation with real compiler/linker tools."""
import argparse
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--tool-root', required=True, type=Path)
parser.add_argument('--out', required=True, type=Path)
args = parser.parse_args()
source = Path(__file__).resolve().parents[2] / 'dos-near-data-segment.S'
bin_dir = args.tool_root.resolve() / 'bin'
out = args.out.resolve()
out.mkdir(parents=True, exist_ok=False)
commands = []


def run(command, success=True):
    command = [str(arg) for arg in command]
    result = subprocess.run(command, capture_output=True, text=True, timeout=30)
    commands.append(dict(command=command, exit=result.returncode,
                         stdout=result.stdout, stderr=result.stderr))
    (out / 'commands.json').write_text(json.dumps(commands, indent=2))
    if (result.returncode == 0) != success:
        raise RuntimeError(f'Unexpected exit {result.returncode}: {command}\n{result.stderr}')
    return result.stdout


results = []
for model in ('tiny', 'small'):
    obj = out / f'{model}.o'
    run([bin_dir / 'clang', '--target=ia16-pc-msdos', '-march=8086',
         f'-mmemory-model={model}', '-c', source, '-o', obj])
    relocs = run([bin_dir / 'llvm-readobj', '--relocations', obj])
    assert 'R_386_SEG16' in relocs and '9f!' not in relocs
    for base in (0x1230, 0x2000, 0xffe0):
        script = out / f'{model}-{base:x}.ld'
        script.write_text('SECTIONS { .text 0 : { *(.text) } '
                          f'.data {base} : {{ *(.data) *(.data!) }} '
                          '.aux 0 : { *(".*&") *(".text!") } '
                          '/DISCARD/ : { *(.comment) *(.note*) } }\n')
        binary = script.with_suffix('.bin')
        run([bin_dir / 'ld.lld', '-m', 'elf_ia16', '-T', script,
             '--oformat', 'binary', obj, '-o', binary])
        actual = int.from_bytes(binary.read_bytes()[:2], 'little')
        assert actual == base // 16, (model, base, actual)
        results.append(dict(model=model, data_base=base, segment_word=actual))
(out / 'results.json').write_text(json.dumps(results, indent=2))
print(json.dumps(dict(passed=len(results), results=str(out / 'results.json'))))
