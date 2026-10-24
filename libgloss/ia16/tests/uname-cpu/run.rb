#!/usr/bin/env ruby
# Build and inspect the pinned buggy and checked-out CPU helper revisions.

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'pathname'
require 'shellwords'

BASELINE_REV = 'f0add853331c830ecf0d14d107f6b51e4a0abb13'
HELPER = 'libgloss/ia16/dos-uname-impl.S'
FIXTURE = 'libgloss/ia16/tests/uname-cpu/runtime.S'
EXPECTED_BASELINE = [
  0x8c, 0xd8,       # mov %ds, %ax overwrites the computed alias segment
  0x9c, 0xfa,       # pushf; cli
  0x8b, 0x57, 0xff, # mov -1(%bx), %dx
  0xfe, 0x0f,       # decb (%bx), with BX == 0
  0x8b, 0x47, 0xff, # mov -1(%bx), %ax
  0x9d,             # popf
  0x16, 0x1f        # push %ss; pop %ds, losing entry DS
].freeze
EXPECTED_CANDIDATE = [
  0x9c, 0xfa, 0x1e, # save FLAGS, disable interrupts, save entry DS
  0x8c, 0xd0,       # mov %ss, %ax
  0x89, 0xe2,       # mov %sp, %dx
  0x4a,             # dec %dx
  0xb1, 0x04,       # mov $4, %cl
  0xd3, 0xea,       # shr %cl, %dx
  0x01, 0xd0,       # add %dx, %ax
  0x8e, 0xd8,       # mov %ax, %ds (keep the computed alias)
  0x8b, 0x57, 0xff, # read the word across offset ffff
  0xfe, 0x0f,       # decrement the alias byte
  0x8b, 0x47, 0xff, # read the word again
  0xfe, 0x07,       # restore the alias byte
  0x1f, 0x9d        # restore DS, then FLAGS
].freeze

options = {}
OptionParser.new do |parser|
  parser.banner = 'Usage: ruby run.rb --tool-root DIR --out DIR'
  parser.on('--tool-root DIR', 'Published IA16 Clang toolchain prefix') { |v| options[:tool_root] = Pathname(v).expand_path }
  parser.on('--out DIR', 'Ninja build and evidence directory') { |v| options[:out] = Pathname(v).expand_path }
end.parse!
abort 'both --tool-root and --out are required' unless options[:tool_root] && options[:out]

source_root = Pathname(__dir__).join('../../../../').realpath
fixture_dir = Pathname(__dir__).realpath
out = options[:out]
tool_root = options[:tool_root]
clang = tool_root.join('bin/clang')
lld = tool_root.join('bin/ld.lld')
llvm_nm = tool_root.join('bin/llvm-nm')
llvm_objcopy = tool_root.join('bin/llvm-objcopy')
%w[clang ld.lld llvm-nm llvm-objcopy].each do |tool|
  path = tool_root.join('bin', tool)
  abort "missing tool: #{path}" unless path.file?
end

def capture!(*command)
  stdout, stderr, status = Open3.capture3(*command.map(&:to_s))
  raise "command failed (#{status.exitstatus}): #{command.join(' ')}\n#{stderr}#{stdout}" unless status.success?
  [stdout, stderr]
end

out.mkpath
out.join('baseline').mkpath
out.join('candidate').mkpath
baseline_src = out.join('baseline/dos-uname-impl.S')
candidate_src = source_root.join(HELPER)
baseline_src.dirname.mkpath
out.join('candidate').mkpath
out.join('protected').mkpath
baseline_text, = capture!('git', '-C', source_root, 'show', "#{BASELINE_REV}:#{HELPER}")
baseline_src.write(baseline_text)

build_ninja = out.join('build.ninja')
fixture_asm = fixture_dir.join('runtime.S')
ld_template = source_root.join('libgloss/ia16/dos-mt.ld.in')
ld_script = out.join('runtime.ld')
include_dir = source_root.join('libgloss/ia16')
baseline_obj = out.join('baseline/dos-uname-impl.o')
candidate_obj = out.join('candidate/dos-uname-impl.o')
protected_obj = out.join('protected/dos-uname-impl.o')
fixture_obj = out.join('runtime.o')
baseline_com = out.join('baseline/CPU-PROBE.COM')
candidate_com = out.join('candidate/CPU-PROBE.COM')

def ninja_path(path)
  path.to_s.gsub('$', '$$').gsub(' ', '$ ').gsub(':', '$:')
end

def shell_path(path)
  Shellwords.escape(path.to_s)
end

build_ninja.write(<<~NINJA)
  ninja_required_version = 1.10
  clang = #{shell_path(clang)}
  lld = #{shell_path(lld)}
  include_dir = #{shell_path(include_dir)}
  linker_template = #{shell_path(ld_template)}
  linker_script = #{ninja_path(ld_script)}

  rule assemble
    command = $clang --target=ia16-pc-msdos -march=8086 -D__IA16_CALLCVT_CDECL=1 -I $include_dir -c $in -o $out
    description = AS $out

  rule assemble_protected
    command = $clang --target=ia16-pc-msdos -march=8086 -D__IA16_CALLCVT_CDECL=1 -D__IA16_FEATURE_PROTECTED_MODE=1 -I $include_dir -c $in -o $out
    description = AS protected $out

  rule make_linker_script
    command = sh $linker_template -nostdlib -mclang-runtime > $out
    description = SCRIPT $out

  rule link_com
    command = $lld -m elf_ia16 -T $linker_script $in -o $out
    description = LINK $out

  build #{ninja_path(ld_script)}: make_linker_script #{ninja_path(ld_template)}
  build #{ninja_path(baseline_obj)}: assemble #{ninja_path(baseline_src)}
  build #{ninja_path(candidate_obj)}: assemble #{ninja_path(candidate_src)}
  build #{ninja_path(protected_obj)}: assemble_protected #{ninja_path(candidate_src)}
  build #{ninja_path(fixture_obj)}: assemble #{ninja_path(fixture_asm)}
  build #{ninja_path(baseline_com)}: link_com #{ninja_path(baseline_obj)} #{ninja_path(fixture_obj)} | #{ninja_path(ld_script)}
  build #{ninja_path(candidate_com)}: link_com #{ninja_path(candidate_obj)} #{ninja_path(fixture_obj)} | #{ninja_path(ld_script)}
  build images: phony #{ninja_path(baseline_com)} #{ninja_path(candidate_com)}
  build protected: phony #{ninja_path(protected_obj)}
  build all: phony images protected
NINJA

capture!('ninja', '-C', out, 'all')

def helper_code(object_path, nm, objcopy, scratch)
  symbols, = capture!(nm, '--defined-only', '--numeric-sort', object_path)
  start_line = symbols.lines.find { |line| line.split.last == '__ia16_get_hw_cpu' }
  stop_line = symbols.lines.find { |line| line.split.last == '__msdos_get_kern_ver_str' }
  raise "could not locate helper function in #{object_path}" unless start_line && stop_line
  start = start_line.split.first.to_i(16)
  stop = stop_line.split.first.to_i(16)
  raise "invalid helper symbol range in #{object_path}" unless stop > start
  section_file = scratch
  capture!(objcopy, "--dump-section=.text=#{section_file}", object_path)
  section = section_file.binread
  section.byteslice(start, stop - start)
end

baseline_scratch = out.join('baseline-text.bin')
candidate_scratch = out.join('candidate-text.bin')
baseline_code = helper_code(baseline_obj, llvm_nm, llvm_objcopy, baseline_scratch)
candidate_code = helper_code(candidate_obj, llvm_nm, llvm_objcopy, candidate_scratch)
protected_code = helper_code(protected_obj, llvm_nm, llvm_objcopy, out.join('protected-text.bin'))
baseline_ok = baseline_code&.include?(EXPECTED_BASELINE.pack('C*'))
candidate_ok = candidate_code&.include?(EXPECTED_CANDIDATE.pack('C*'))
protected_ok = protected_code && !protected_code.include?([0xfa].pack('C')) &&
  !protected_code.include?([0xd6].pack('C')) && !protected_code.include?([0xfe, 0x0f].pack('C*'))
fixture_text = fixture_asm.read
residues = fixture_text.scan(/^\s*probe\s+0xf00[0-9a-f],/i).length
raise "fixture has #{residues} SP residues, expected 16" unless residues == 16

report = {
  baseline_revision: BASELINE_REV,
  baseline_source_sha256: Digest::SHA256.hexdigest(baseline_text),
  candidate_source_sha256: Digest::SHA256.file(candidate_src).hexdigest,
  baseline_object_sha256: Digest::SHA256.file(baseline_obj).hexdigest,
  candidate_object_sha256: Digest::SHA256.file(candidate_obj).hexdigest,
  fixture_object_sha256: Digest::SHA256.file(fixture_obj).hexdigest,
  baseline_com_sha256: Digest::SHA256.file(baseline_com).hexdigest,
  candidate_com_sha256: Digest::SHA256.file(candidate_com).hexdigest,
  baseline_bug_sequence_found: !!baseline_ok,
  candidate_repair_sequence_found: !!candidate_ok,
  protected_mode_probe_absent: !!protected_ok,
  fixture_stack_residues: residues,
  scratch_marker_checked_residues: 14,
  candidate_result: candidate_ok && protected_ok ? 'object-repair-sequences-present' : 'RED: required repair sequence is absent'
}
out.join('results.json').write(JSON.pretty_generate(report) + "\n")
puts JSON.pretty_generate(report)
exit(candidate_ok && protected_ok ? 0 : 1)
