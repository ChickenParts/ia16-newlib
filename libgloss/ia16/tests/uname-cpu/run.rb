#!/usr/bin/env ruby
# Build DOS and bare-machine images and record the linked CS-relative receipt.

require 'digest'
require 'json'
require 'open3'
require 'optparse'
require 'pathname'
require 'shellwords'

BASELINE_REV = 'f0add853331c830ecf0d14d107f6b51e4a0abb13'
HELPER = 'libgloss/ia16/dos-uname-impl.S'
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
  [0x9c, 0xfa, 0x1e, 0x16, 0x1f], # save flags/DS, then normalize DS to SS
  [0x8c, 0xd0, 0x89, 0xe2, 0x4a, 0xb1, 0x04, 0xd3, 0xea, 0x01, 0xd0,
   0x8e, 0xd8, 0x8b, 0x57, 0xff, 0xfe, 0x0f, 0x8b, 0x47, 0xff, 0xfe, 0x07],
  [0xb0, 0x03, 0x1f, 0x9d, 0x98] # final class byte, restore DS/FLAGS, sign extend
].freeze
RECEIPT_BYTES = ['IA24'.bytes, [1, 0, 16, 0xff, 0xff, 0xff].freeze,
                 Array.new(32, 0xff)].flatten.freeze

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

def ninja_path(path)
  path.to_s.gsub('$', '$$').gsub(' ', '$ ').gsub(':', '$:')
end

def shell_path(path)
  Shellwords.escape(path.to_s)
end

def section_bytes(object_path, section_name, objcopy, scratch)
  capture!(objcopy, "--dump-section=#{section_name}=#{scratch}", object_path)
  scratch.binread
end

def helper_code(object_path, nm, objcopy, scratch)
  symbols, = capture!(nm, '--defined-only', '--numeric-sort', object_path)
  start_line = symbols.lines.find { |line| line.split.last == '__ia16_get_hw_cpu' }
  stop_line = symbols.lines.find { |line| line.split.last == '__msdos_get_kern_ver_str' }
  raise "could not locate helper function in #{object_path}" unless start_line && stop_line
  start = start_line.split.first.to_i(16)
  stop = stop_line.split.first.to_i(16)
  raise "invalid helper symbol range in #{object_path}" unless stop > start
  text = section_bytes(object_path, '.text', objcopy, scratch)
  text.byteslice(start, stop - start)
end

def ordered_sequences?(bytes, sequences)
  offset = 0
  sequences.all? do |sequence|
    found = bytes.index(sequence.pack('C*'), offset)
    next false unless found
    offset = found + sequence.length
    true
  end
end

def symbols_for(nm, elf)
  output, = capture!(nm, '--defined-only', '--numeric-sort', elf)
  output.lines.each_with_object({}) do |line, symbols|
    fields = line.split
    symbols[fields.last] = fields.first.to_i(16) if fields.length >= 3 && fields.first.match?(/\A[0-9a-f]+\z/i)
  end
end

def image_metadata(name, elf, image, nm)
  symbols = symbols_for(nm, elf)
  start = symbols.fetch('_start')
  receipt = symbols.fetch('__ia16_cpu_receipt')
  classes = symbols.fetch('__ia16_cpu_classes')
  image_end = [symbols.fetch('__etext'), symbols.fetch('__edata'),
               symbols.fetch('__ebss'), start + image.size].max
  raise "#{name}: expected _start at VMA 0x100, got 0x#{start.to_s(16)}" unless start == 0x100
  raise "#{name}: receipt classes are not 10 bytes after receipt" unless classes == receipt + 10
  raise "#{name}: image end 0x#{image_end.to_s(16)} overlaps DS sentinel at CS:2000" unless image_end < 0x2000
  raise "#{name}: image end 0x#{image_end.to_s(16)} reaches the test stack at CS:f000" unless image_end < 0xf000
  bytes = image.binread
  offset = receipt - start
  actual = bytes.byteslice(offset, RECEIPT_BYTES.length)
  raise "#{name}: initialized receipt does not match documented layout" unless actual == RECEIPT_BYTES.pack('C*')
  {
    image: image.to_s,
    image_sha256: Digest::SHA256.file(image).hexdigest,
    entry_vma: start,
    receipt_vma: receipt,
    classes_vma: classes,
    image_end_vma: image_end,
    image_end_vma_hex: format('0x%x', image_end),
    ds_sentinel_cs_offset: 0x2000,
    initial_receipt_hex: actual.unpack1('H*')
  }
end

out.mkpath
%w[baseline candidate protected].each { |dir| out.join(dir).mkpath }
source_root_path = source_root.to_s
baseline_src = out.join('baseline/dos-uname-impl.S')
candidate_src = source_root.join(HELPER)
baseline_text, = capture!('git', '-C', source_root, 'show', "#{BASELINE_REV}:#{HELPER}")
baseline_src.write(baseline_text)

fixture_asm = fixture_dir.join('runtime.S')
ld_template = source_root.join('libgloss/ia16/dos-mt.ld.in')
ld_script = out.join('runtime-elf.ld')
ld_script_text, = capture!('sh', ld_template, '-nostdlib', '-mclang-runtime')
unless ld_script_text.include?('OUTPUT_FORMAT(binary)')
  abort 'DOS linker template did not contain OUTPUT_FORMAT(binary)'
end
ld_script.write(ld_script_text.sub('OUTPUT_FORMAT(binary)', 'OUTPUT_FORMAT(elf32-i386)'))

baseline_obj = out.join('baseline/dos-uname-impl.o')
candidate_obj = out.join('candidate/dos-uname-impl.o')
protected_obj = out.join('protected/dos-uname-impl.o')
dos_fixture_obj = out.join('runtime-dos.o')
bare_fixture_obj = out.join('runtime-bare.o')
baseline_dos_elf = out.join('baseline/dos.elf')
candidate_dos_elf = out.join('candidate/dos.elf')
baseline_bare_elf = out.join('baseline/bare.elf')
candidate_bare_elf = out.join('candidate/bare.elf')
baseline_dos_image = out.join('baseline/CPU-PROBE.COM')
candidate_dos_image = out.join('candidate/CPU-PROBE.COM')
baseline_bare_image = out.join('baseline/CPU-PROBE.BIN')
candidate_bare_image = out.join('candidate/CPU-PROBE.BIN')

build_ninja = out.join('build.ninja')
include_dir = source_root.join('libgloss/ia16')
build_ninja.write(<<~NINJA)
  ninja_required_version = 1.10
  clang = #{shell_path(clang)}
  lld = #{shell_path(lld)}
  objcopy = #{shell_path(llvm_objcopy)}
  include_dir = #{shell_path(include_dir)}
  linker_script = #{ninja_path(ld_script)}

  rule assemble
    command = $clang --target=ia16-pc-msdos -march=8086 -D__IA16_CALLCVT_CDECL=1 -I $include_dir -c $in -o $out
    description = AS $out

  rule assemble_bare
    command = $clang --target=ia16-pc-msdos -march=8086 -D__IA16_CALLCVT_CDECL=1 -DIA16_CPU_BARE_EXIT=1 -I $include_dir -c $in -o $out
    description = AS bare $out

  rule assemble_protected
    command = $clang --target=ia16-pc-msdos -march=8086 -D__IA16_CALLCVT_CDECL=1 -D__IA16_FEATURE_PROTECTED_MODE=1 -I $include_dir -c $in -o $out
    description = AS protected $out

  rule link_elf
    command = $lld -m elf_ia16 -T $linker_script $in -o $out
    description = LINK $out

  rule raw_image
    command = $objcopy -O binary $in $out
    description = RAW $out

  build #{ninja_path(baseline_obj)}: assemble #{ninja_path(baseline_src)}
  build #{ninja_path(candidate_obj)}: assemble #{ninja_path(candidate_src)}
  build #{ninja_path(protected_obj)}: assemble_protected #{ninja_path(candidate_src)}
  build #{ninja_path(dos_fixture_obj)}: assemble #{ninja_path(fixture_asm)}
  build #{ninja_path(bare_fixture_obj)}: assemble_bare #{ninja_path(fixture_asm)}

  build #{ninja_path(baseline_dos_elf)}: link_elf #{ninja_path(baseline_obj)} #{ninja_path(dos_fixture_obj)} | #{ninja_path(ld_script)}
  build #{ninja_path(candidate_dos_elf)}: link_elf #{ninja_path(candidate_obj)} #{ninja_path(dos_fixture_obj)} | #{ninja_path(ld_script)}
  build #{ninja_path(baseline_bare_elf)}: link_elf #{ninja_path(baseline_obj)} #{ninja_path(bare_fixture_obj)} | #{ninja_path(ld_script)}
  build #{ninja_path(candidate_bare_elf)}: link_elf #{ninja_path(candidate_obj)} #{ninja_path(bare_fixture_obj)} | #{ninja_path(ld_script)}
  build #{ninja_path(baseline_dos_image)}: raw_image #{ninja_path(baseline_dos_elf)}
  build #{ninja_path(candidate_dos_image)}: raw_image #{ninja_path(candidate_dos_elf)}
  build #{ninja_path(baseline_bare_image)}: raw_image #{ninja_path(baseline_bare_elf)}
  build #{ninja_path(candidate_bare_image)}: raw_image #{ninja_path(candidate_bare_elf)}
  build images: phony #{ninja_path(baseline_dos_image)} #{ninja_path(candidate_dos_image)} #{ninja_path(baseline_bare_image)} #{ninja_path(candidate_bare_image)}
  build protected: phony #{ninja_path(protected_obj)}
  build all: phony images protected
NINJA

capture!('ninja', '-C', out, 'all')

baseline_code = helper_code(baseline_obj, llvm_nm, llvm_objcopy, out.join('baseline-text.bin'))
candidate_code = helper_code(candidate_obj, llvm_nm, llvm_objcopy, out.join('candidate-text.bin'))
protected_code = helper_code(protected_obj, llvm_nm, llvm_objcopy, out.join('protected-text.bin'))
baseline_ok = baseline_code&.include?(EXPECTED_BASELINE.pack('C*'))
candidate_ok = candidate_code && ordered_sequences?(candidate_code, EXPECTED_CANDIDATE)
protected_ok = protected_code && !protected_code.include?([0xfa].pack('C')) &&
  !protected_code.include?([0xd6].pack('C')) && !protected_code.include?([0xfe, 0x0f].pack('C*'))
bare_text = section_bytes(bare_fixture_obj, '.startupA', llvm_objcopy, out.join('bare-startup.bin'))
bare_exit_ok = bare_text.include?([0xe6, 0xf4].pack('C')) && !bare_text.include?([0xcd, 0x21].pack('C*'))
runtime_text = fixture_asm.read
residues = runtime_text.scan(/^\s*probe\s+0xf00[0-9a-f],/i).length
raise "fixture has #{residues} SP residues, expected 16" unless residues == 16

images = {
  baseline_dos: image_metadata('baseline DOS image', baseline_dos_elf, baseline_dos_image, llvm_nm),
  candidate_dos: image_metadata('candidate DOS image', candidate_dos_elf, candidate_dos_image, llvm_nm),
  baseline_bare: image_metadata('baseline bare image', baseline_bare_elf, baseline_bare_image, llvm_nm),
  candidate_bare: image_metadata('candidate bare image', candidate_bare_elf, candidate_bare_image, llvm_nm)
}
report = {
  baseline_revision: BASELINE_REV,
  baseline_source_sha256: Digest::SHA256.hexdigest(baseline_text),
  candidate_source_sha256: Digest::SHA256.file(candidate_src).hexdigest,
  baseline_object_sha256: Digest::SHA256.file(baseline_obj).hexdigest,
  candidate_object_sha256: Digest::SHA256.file(candidate_obj).hexdigest,
  protected_object_sha256: Digest::SHA256.file(protected_obj).hexdigest,
  dos_fixture_object_sha256: Digest::SHA256.file(dos_fixture_obj).hexdigest,
  bare_fixture_object_sha256: Digest::SHA256.file(bare_fixture_obj).hexdigest,
  baseline_bug_sequence_found: !!baseline_ok,
  candidate_repair_sequence_found: !!candidate_ok,
  protected_mode_probe_absent: !!protected_ok,
  bare_exit_is_out_f4_al_without_int21: !!bare_exit_ok,
  stack_residues: residues,
  scratch_marker_checked_residues: 14,
  receipt_layout: {
    magic: 'IA24', version: 1, status_pending: 0, status_pass: 1,
    status_fail: 2, case_count: 16, failure_index: 0xff,
    expected_class_offset: 8, classes_offset: 10,
    class_width_bytes: 2, class_order: 'entry SP residue 0 through 15'
  },
  images: images
}
out.join('results.json').write(JSON.pretty_generate(report) + "\n")
puts JSON.pretty_generate(report)
exit(baseline_ok && candidate_ok && protected_ok && bare_exit_ok ? 0 : 1)
