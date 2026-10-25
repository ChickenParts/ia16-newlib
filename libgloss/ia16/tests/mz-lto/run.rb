#!/usr/bin/env ruby
# Build small-model DOS MZ variants; DOS execution is deliberately separate.
require 'json'
require 'fileutils'
require 'open3'
require 'optparse'
require 'pathname'
require 'digest'
require 'shellwords'

options = {}
OptionParser.new do |parser|
  parser.banner = 'Usage: run.rb --tool-root DIR --runtime-root DIR --out DIR'
  parser.on('--tool-root DIR', 'Candidate LLVM installation containing bin/ and lib/') { |v| options[:tool_root] = v }
  parser.on('--runtime-root DIR', 'Matching IA16 sysroot or prefix containing ia16-pc-msdos/') { |v| options[:runtime_root] = v }
  parser.on('--out DIR', 'New or existing build and receipt directory') { |v| options[:out] = v }
end.parse!

missing = %i[tool_root runtime_root out].reject { |key| options[key] }
abort "missing required options: #{missing.join(', ')}" unless missing.empty?

fixture = Pathname(__FILE__).realpath.dirname
ia16_source = fixture.parent.parent
script_template = ia16_source / 'dos-mx.ld.in'
tool_root = Pathname(options.fetch(:tool_root)).realpath
runtime_root = Pathname(options.fetch(:runtime_root)).realpath
runtime = if (runtime_root / 'lib/dos-s-c0.o').file?
            runtime_root
          else
            nested = runtime_root / 'ia16-pc-msdos'
            abort "runtime root has no lib/dos-s-c0.o: #{runtime_root}" unless (nested / 'lib/dos-s-c0.o').file?
            nested
          end
out = Pathname(options.fetch(:out)).expand_path
[out, tool_root, runtime].each do |path|
  abort "Ninja command paths may not contain whitespace: #{path}" if path.to_s.match?(/\s/)
end
abort "missing candidate clang: #{tool_root}/bin/clang" unless (tool_root / 'bin/clang').file?
abort "missing candidate ld.lld: #{tool_root}/bin/ld.lld" unless (tool_root / 'bin/ld.lld').file?
abort "missing compiler-rt archive: #{runtime}/lib/libclang_rt.builtins-ia16.a" unless (runtime / 'lib/libclang_rt.builtins-ia16.a').file?
abort "missing DOS libraries under #{runtime}/lib" unless (runtime / 'lib/libc.a').file? && (runtime / 'lib/libdos-s.a').file?
out.mkpath

commands = []
def run_logged(argv, commands, out, label, expect_failure: nil)
  stdout, stderr, status = Open3.capture3(*argv.map(&:to_s))
  commands << {
    label: label,
    argv: argv.map(&:to_s),
    exit: status.exitstatus,
    stdout: stdout,
    stderr: stderr,
    expected_failure: !expect_failure.nil?
  }
  File.write(out / 'commands.json', JSON.pretty_generate(commands) + "\n")
  if expect_failure
    output = stdout + stderr
    unless !status.success? && output.include?(expect_failure)
      raise "#{label} did not fail with #{expect_failure.inspect}; see #{out}/commands.json"
    end
    return output
  end
  return stdout if status.success?

  raise "#{label} failed (#{status.exitstatus}); see #{out}/commands.json"
end

resource = run_logged([tool_root / 'bin/clang', '-print-resource-dir'], commands, out, 'resource-dir').strip
script = out / 'dos-clang-small.ld'
script_text = run_logged(['sh', script_template, '-nostdlib', '-mclang-runtime'], commands, out, 'generate-small-mz-script')
File.write(script, script_text)

q = ->(path) { Shellwords.escape(path.to_s) }
clang = q.call(tool_root / 'bin/clang')
ld = q.call(tool_root / 'bin/ld.lld')
sysroot = q.call(runtime)
resource = q.call(resource)
script = q.call(script)
builtins = q.call(runtime / 'lib/libclang_rt.builtins-ia16.a')
source = ->(name) { q.call(fixture / name) }

ninja = <<~NINJA
  ninja_required_version = 1.10
  clang = #{clang}
  ld = #{ld}
  sysroot = #{sysroot}
  resource = #{resource}
  script = #{script}
  builtins = #{builtins}

  rule compile
    command = $clang --target=ia16-pc-msdos -march=8086 -mmemory-model=small -std=gnu23 -Oz -ffunction-sections -fdata-sections -femulated-tls -fno-builtin -nostdinc -isystem $sysroot/include -isystem $sysroot/include/newlib -isystem $resource/include $mode $define -c $in -o $out
  rule link
    command = $ld -m elf_ia16 -plugin-opt=mcpu=8086 -plugin-opt=-emulated-tls -T $script -L $sysroot/lib --gc-sections $sysroot/lib/dos-s-c0.o $in --start-group -lc -ldos-s -lm $builtins --end-group -Map=$out.map -o $out

  build native_main.o: compile #{source.call('main.c')}
    mode =
    define =
  build native_tls.o: compile #{source.call('tls.c')}
    mode =
    define =
  build native_logic.o: compile #{source.call('logic.c')}
    mode =
    define =
  build native_dormant.o: compile #{source.call('dormant.c')}
    mode =
    define =
  build native.exe: link native_main.o native_tls.o native_logic.o native_dormant.o | dos-clang-small.ld

  build full_main.o: compile #{source.call('main.c')}
    mode = -flto
    define =
  build full_tls.o: compile #{source.call('tls.c')}
    mode = -flto
    define =
  build full_logic.o: compile #{source.call('logic.c')}
    mode = -flto
    define =
  build full_dormant.o: compile #{source.call('dormant.c')}
    mode = -flto
    define =
  build full.exe: link full_main.o full_tls.o full_logic.o full_dormant.o | dos-clang-small.ld

  build thin_main.o: compile #{source.call('main.c')}
    mode = -flto=thin
    define =
  build thin_tls.o: compile #{source.call('tls.c')}
    mode = -flto=thin
    define =
  build thin_logic.o: compile #{source.call('logic.c')}
    mode = -flto=thin
    define =
  build thin_dormant.o: compile #{source.call('dormant.c')}
    mode = -flto=thin
    define =
  build thin.exe: link thin_main.o thin_tls.o thin_logic.o thin_dormant.o | dos-clang-small.ld

  build full23_main.o: compile #{source.call('main.c')}
    mode = -flto
    define = -DRETURN_NONZERO=1
  build full23.exe: link full23_main.o full_tls.o full_logic.o full_dormant.o | dos-clang-small.ld

  build all: phony native.exe full.exe thin.exe full23.exe
  default all
NINJA
File.write(out / 'build.ninja', ninja)

run_logged(['ninja', '-C', out, '-f', 'build.ninja', '-v', 'all'], commands, out, 'build-mz-lto-variants')

maps = %w[native full thin].to_h do |lane|
  [lane, File.read(out / "#{lane}.exe.map")]
end
sizes = %w[native full thin full23].to_h do |lane|
  [lane, (out / "#{lane}.exe").size]
end
code_extents = maps.transform_values do |map|
  line = map.lines.find do |candidate|
    fields = candidate.strip.split(/\s+/, 5)
    fields.length == 5 && fields[4] == '.text'
  end
  raise 'link map is missing the .text output section' unless line
  fields = line.strip.split(/\s+/, 5)
  vma = Integer(fields[0], 16)
  size = Integer(fields[2], 16)
  { vma: vma, size: size, end: vma + size }
end
dormant_code = maps.transform_values do |map|
  map.include?('(.text.dormant_payload)')
end
unless dormant_code.fetch('native')
  raise "native map did not retain cross-TU dormant payload; see #{out}/native.exe.map"
end
unless %w[full thin].all? { |lane| !dormant_code.fetch(lane) }
  raise "LTO maps retained the dormant function section: #{dormant_code.inspect}"
end
unless %w[full thin].all? { |lane| sizes.fetch(lane) < sizes.fetch('native') }
  raise "LTO did not reduce the linked MZ size below native: #{sizes.inspect}"
end
unless code_extents.values.all? { |section| section.fetch(:end) <= 0x10000 }
  raise "an output .text section exceeds the 64KB code segment: #{code_extents.inspect}"
end

batch = <<~BAT.gsub("\n", "\r\n")
  @echo off
  echo START> START.TXT
  NATIVE.EXE > NATIVE.OUT
  if errorlevel 1 goto fail
  echo EXIT=0> NATIVE.STS
  FULL.EXE > FULL.OUT
  if errorlevel 1 goto fail
  echo EXIT=0> FULL.STS
  THIN.EXE > THIN.OUT
  if errorlevel 1 goto fail
  echo EXIT=0> THIN.STS
  FULL23.EXE > FULL23.OUT
  if errorlevel 24 goto fail
  if not errorlevel 23 goto fail
  echo EXIT=23> FULL23.STS
  echo DONE> DONE.TXT
  goto end
  :fail
  echo FAIL> FAIL.TXT
  :end
BAT
guest_drive = out / 'drive'
FileUtils.rm_rf(guest_drive)
guest_drive.mkpath
%w[native full thin full23].each do |lane|
  FileUtils.cp(out / "#{lane}.exe", guest_drive / "#{lane}.exe")
end
(guest_drive / 'RUNALL.BAT').binwrite(batch)
dosbox_config = <<~CONF
  [sdl]
  fullscreen=false
  output=opengl
  [cpu]
  core=normal
  cputype=8086
  cycles=max
  [mixer]
  nosound=true
  [autoexec]
  @echo off
  mount c "#{guest_drive}"
  c:
  RUNALL.BAT
  exit
CONF
(out / 'dosbox.conf').write(dosbox_config)

summary = {
  target: 'ia16-pc-msdos small near model, 8086',
  built: sizes.keys,
  executable_bytes: sizes,
  executable_sha256: %w[native full thin full23].to_h do |lane|
    [lane, Digest::SHA256.file(out / "#{lane}.exe").hexdigest]
  end,
  compiler: (tool_root / 'bin/clang').to_s,
  compiler_sha256: Digest::SHA256.file(tool_root / 'bin/clang').hexdigest,
  linker: (tool_root / 'bin/ld.lld').to_s,
  linker_sha256: Digest::SHA256.file(tool_root / 'bin/ld.lld').hexdigest,
  runtime: runtime.to_s,
  runtime_sha256: {
    crt: Digest::SHA256.file(runtime / 'lib/dos-s-c0.o').hexdigest,
    libc: Digest::SHA256.file(runtime / 'lib/libc.a').hexdigest,
    libdos: Digest::SHA256.file(runtime / 'lib/libdos-s.a').hexdigest,
    builtins: Digest::SHA256.file(runtime / 'lib/libclang_rt.builtins-ia16.a').hexdigest
  },
  linker_script_sha256: Digest::SHA256.file(script).hexdigest,
  code_section_vma_size_end: code_extents,
  dormant_function_section_present: dormant_code,
  lto_reduces_exe_size: sizes.fetch('full') < sizes.fetch('native'),
  thinlto_reduces_exe_size: sizes.fetch('thin') < sizes.fetch('native'),
  guest_drive: guest_drive.to_s,
  guest_command_file: (guest_drive / 'RUNALL.BAT').to_s,
  dosbox_config: (out / 'dosbox.conf').to_s,
  link_maps: %w[native full thin].to_h { |lane| [lane, (out / "#{lane}.exe.map").to_s] }
}
File.write(out / 'build-results.json', JSON.pretty_generate(summary) + "\n")
puts JSON.pretty_generate(summary)
