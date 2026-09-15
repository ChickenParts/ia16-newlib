#!/usr/bin/env python3
"""Build and stage the near-pointer IA16 DOS Clang/newlib profile."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess

TARGET = 'ia16-pc-msdos'
p = argparse.ArgumentParser(description=__doc__)
for option in ('source-root', 'tool-root', 'build-root', 'install-prefix', 'builtins'):
    p.add_argument('--' + option, type=Path, required=True)
p.add_argument('--jobs', type=int, default=4)
a = p.parse_args()
source, tools, build, install, builtins = (
    x.resolve() for x in (a.source_root, a.tool_root, a.build_root,
                         a.install_prefix, a.builtins))
if a.jobs < 1:
    p.error('--jobs must be positive')
for name, path in [('build', build), ('install', install)]:
    if path.exists():
        p.error(f'{name} output already exists: {path}')
# Autoconf/Make consume these paths as command fragments, even though this
# script itself never uses shell=True. Refuse Make/shell metacharacters.
for path in (source, tools, build, install, builtins):
    if any(c.isspace() or c in '$#`\\\"\';&|<>(){}[]*?!' for c in str(path)):
        p.error(f'Autoconf build paths must not contain whitespace or shell/Make metacharacters: {path}')
for path in (source / 'configure', tools / 'bin/clang', tools / 'bin/ld.lld', builtins):
    if not path.is_file():
        p.error(f'required input missing: {path}')
build.mkdir(parents=True)
install.mkdir(parents=True)
manifest = {'status': 'running', 'source_root': str(source),
            'tool_root': str(tools), 'build_root': str(build),
            'install_prefix': str(install), 'target': TARGET, 'commands': []}

def digest(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()

def save():
    (build / 'build-profile.json').write_text(json.dumps(manifest, indent=2) + '\n')

def run(name, command, env=None, cwd=build):
    command = [str(x) for x in command]
    log = build / (name + '.log')
    entry = {'command': command, 'cwd': str(cwd), 'log': str(log)}
    manifest['commands'].append(entry)
    save()
    with log.open('w') as stream:
        stream.write('$ ' + shlex.join(command) + '\n')
        stream.flush()
        result = subprocess.run(command, cwd=cwd, env=env, stdout=stream,
                                stderr=subprocess.STDOUT)
    entry['exit'] = result.returncode
    save()
    if result.returncode:
        raise RuntimeError(f'{name} failed ({result.returncode}); see {log}')

try:
    clang = tools / 'bin/clang'
    resource = Path(subprocess.check_output([clang, '-print-resource-dir'], text=True).strip()).resolve()
    manifest['builder_sha256'] = digest(Path(__file__).resolve())
    manifest['compiler_sha256'] = digest(clang)
    manifest['linker_sha256'] = digest(tools / 'bin/ld.lld')
    manifest['builtins_sha256'] = digest(builtins)
    manifest['source_commit'] = subprocess.check_output(
        ['git', '-C', source, 'rev-parse', 'HEAD'], text=True).strip()
    manifest['source_status'] = subprocess.check_output(
        ['git', '-C', source, 'status', '--porcelain'], text=True)
    source_diff = subprocess.check_output(['git', '-C', source, 'diff', '--binary'])
    (build / 'source.diff').write_bytes(source_diff)
    manifest['source_diff_sha256'] = digest(build / 'source.diff')
    overlay = build / TARGET / 'newlib/targ-include'
    generic = source / 'newlib/libc/include'
    cc = shlex.join([str(clang), '--target=' + TARGET, '-march=8086',
                    '-mmemory-model=small', '-nostdinc',
                    '-I' + str(overlay), '-I' + str(generic),
                    '-isystem', str(overlay), '-isystem', str(generic),
                    '-isystem', str(resource / 'include')])
    flags = '-std=gnu17 -Os -femulated-tls -ffreestanding -fno-builtin -nostdinc'
    env = dict(os.environ)
    for key in ('CPATH', 'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH', 'OBJC_INCLUDE_PATH',
                'COMPILER_PATH', 'LIBRARY_PATH', 'GCC_EXEC_PREFIX'):
        env.pop(key, None)
    settings = {'CC_FOR_TARGET': cc, 'AS_FOR_TARGET': cc,
                'CFLAGS_FOR_TARGET': flags, 'CPPFLAGS_FOR_TARGET': '',
                'libc_cv_compiler_isystem': '-isystem ' + str(resource / 'include')}
    for var, tool in [('AR', 'ar'), ('RANLIB', 'ranlib'), ('NM', 'nm'), ('OBJCOPY', 'objcopy')]:
        found = shutil.which(tool)
        if not found:
            raise RuntimeError(f'required host tool missing: {tool}')
        settings[var + '_FOR_TARGET'] = found
    settings['LD_FOR_TARGET'] = str(tools / 'bin/ld.lld')
    env.update(settings)
    manifest['target_environment'] = settings
    run('configure', [source / 'configure', '--target=' + TARGET,
        '--prefix=' + str(install), '--disable-nls', '--disable-multilib',
        '--disable-werror'], env=env)
    run('make', ['make', '-j' + str(a.jobs)], env=env)
    run('install', ['make', 'install'], env=env)
    target = install / TARGET
    shutil.copytree(generic, target / 'include/newlib')
    shutil.copy2(builtins, target / 'lib/libclang_rt.builtins-ia16.a')
    for model, template in [('tiny', 'dos-mt.ld.in'), ('small', 'dos-mx.ld.in')]:
        output = subprocess.check_output(['sh', source / 'libgloss/ia16' / template,
                                          '-nostdlib'], text=True)
        (target / 'lib' / ('dos-clang-' + model + '.ld')).write_text(output)
    # The maintained oracle verifies GNU23 widths and both include_next tiers,
    # and rejects any header read outside the explicit target/resource trees.
    run('headers', ['python3', source / 'libgloss/ia16/tools/stage-clang-sysroot.py',
        '--source-root', source, '--tool-root', tools, '--build-root', build,
        '--install-prefix', install, '--output', install / 'header-profile'], env=env)
    header_result = json.loads((install / 'header-profile/results.json').read_text())
    manifest['header_trace'] = header_result['traced_headers']
    manifest['headers_outside_allowed_roots'] = header_result['include_paths_outside_allowed_roots']
    profile = ['# Generated near-pointer DOS profile; source this file.']
    for model, letter in [('tiny', 't'), ('small', 's')]:
        compile_flags = [clang, '--target=' + TARGET, '-march=8086',
            '-mmemory-model=' + model, '-std=gnu23', '-Os', '-femulated-tls',
            '-ffreestanding', '-fno-builtin', '-nostdinc',
            '-isystem', target / 'include', '-isystem', target / 'include/newlib',
            '-isystem', resource / 'include']
        profile += ['ia16_clang_' + model + '() {',
                    '  ' + shlex.join(map(str, compile_flags)) + ' "$@"', '}']
        link_flags = [tools / 'bin/ld.lld', '-m', 'elf_ia16', '-T',
            target / 'lib' / ('dos-clang-' + model + '.ld'),
            '-L', target / 'lib', target / 'lib' / ('dos-' + letter + '-c0.o')]
        profile += ['ia16_link_' + model + '() {',
            '  ' + shlex.join(map(str, link_flags)) + ' "$@" --start-group -lc -ldos-' +
            letter + ' -lm ' + shlex.quote(str(target / 'lib/libclang_rt.builtins-ia16.a')) +
            ' --end-group', '}']
    (install / 'profile.sh').write_text('\n'.join(profile) + '\n')
    manifest['installed_archives'] = {x.name: digest(x) for x in sorted((target / 'lib').glob('*.a'))}
    for name, path in [('compiler', clang), ('linker', tools / 'bin/ld.lld')]:
        if digest(path) != manifest[name + '_sha256']:
            raise RuntimeError(f'{name} changed during the build; rebuild with stable tools')
    if digest(target / 'lib/libclang_rt.builtins-ia16.a') != manifest['builtins_sha256']:
        raise RuntimeError('staged builtins do not match the input manifest')
    manifest['status'] = 'pass'
    save()
    print(json.dumps({'status': 'pass', 'profile': str(install / 'profile.sh'),
                      'manifest': str(build / 'build-profile.json')}))
except Exception as error:
    manifest['status'] = 'fail'
    manifest['error'] = str(error)
    save()
    raise
