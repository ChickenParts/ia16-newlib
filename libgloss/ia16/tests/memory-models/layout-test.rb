#!/usr/bin/env ruby
# Real compiler/linker tests: no sysroot or DOS emulator is needed.
require 'minitest/autorun'
require 'tmpdir'
require 'open3'
require 'pathname'
require_relative '../../tools/generate-dos-clang-mz'

class IA16SegmentPackingTest < Minitest::Test
  IA16 = Pathname(__dir__).realpath.parent.parent
  TOOLS = Pathname(ENV.fetch('IA16_LLVM_BIN'))
  def setup
    @dir = Dir.mktmpdir('ia16-segments-', ENV.fetch('TMPDIR', '/tmp'))
    template = (IA16 / 'dos-clang-mz.ld.in').read
    File.write(File.join(@dir, 'dos.ld'), IA16ClangSysroot.dos_clang_mz_script(template))
  end
  def teardown
    FileUtils.remove_entry(@dir)
  end
  def run_command(*args)
    stdout, stderr, status = Open3.capture3(*args.map(&:to_s), chdir: @dir)
    assert status.success?, "#{args.join(' ')}\n#{stdout}\n#{stderr}"
    [stdout, stderr]
  end
  def build(model, source)
    File.write(File.join(@dir, 'input.c'), source)
    run_command(TOOLS / 'clang', '--target=ia16-pc-msdos', '-march=8086',
      "-mmemory-model=#{model}", '-ffreestanding', '-Oz', '-c', 'input.c', '-o', 'input.o')
    run_command(TOOLS / 'ld.lld', '-m', 'elf_ia16', '--oformat=mz', '-T', 'dos.ld',
      'input.o', '-o', 'output.exe', '--Map=output.map')
    File.read(File.join(@dir, 'output.map'))
  end
  def test_medium_bss_alignment_after_four_byte_data
   File.write(File.join(@dir, 'input.c'), <<~'C')
     volatile unsigned short word[2] = {1, 2};
     volatile unsigned long datum __attribute__((aligned(4)));
     int _start(void) { datum = word[0] + word[1]; return (int)datum; }
   C
   run_command(TOOLS / 'clang', '--target=ia16-pc-msdos', '-march=8086',
     '-mmemory-model=medium', '-ffreestanding', '-fno-common', '-c', 'input.c', '-o', 'input.o')
   _, stderr = run_command(TOOLS / 'ld.lld', '-m', 'elf_ia16', '--oformat=mz',
     '-T', 'dos.ld', 'input.o', '-o', 'output.exe', '--Map=output.map')
   refute_match(/alignment/, stderr, 'medium BSS must not trigger an alignment warning')
   map = File.read(File.join(@dir, 'output.map'))
   line = map.lines.find { |entry| entry.match?(/\sdatum$/) }
   refute_nil line, 'medium: missing datum'
   vma, lma = line.split.first(2).map { |value| value.to_i(16) }
   assert_equal 0, vma % 4, 'datum VMA'
   assert_equal 0, lma % 4, 'datum LMA'
  end
  def test_initial_allocation_symbol_matches_the_mz_loader_minimum
    %w[small medium compact large].each do |model|
      [nil, 0x800].each do |stack_size|
        File.write(File.join(@dir, 'input.c'), <<~C)
          extern const char __msdos_initial_alloc_paras[];
          volatile unsigned char data[32] = {1};
          volatile unsigned char bss[32];
          #{'volatile unsigned char far_payload[0x9000] = {1};' if %w[compact large].include?(model)}
          unsigned short _start(void) {
            bss[0] = data[0];
            return (unsigned short)__msdos_initial_alloc_paras;
          }
        C
        run_command(TOOLS / 'clang', '--target=ia16-pc-msdos', '-march=8086',
          "-mmemory-model=#{model}", '-ffreestanding', '-c', 'input.c', '-o', 'input.o')
        flags = stack_size ? ["--defsym=__stack_size=#{stack_size}"] : []
        run_command(TOOLS / 'ld.lld', '-m', 'elf_ia16', '--oformat=mz',
          '-T', 'dos.ld', *flags, 'input.o', '-o', 'output.exe')
        run_command(TOOLS / 'ld.lld', '-m', 'elf_ia16', '--no-check-sections', '-T', 'dos.ld',
          *flags, 'input.o', '-o', 'output.elf')
        symbols, = run_command(TOOLS / 'llvm-nm', '--defined-only', 'output.elf')
        symbol = symbols.match(/^(\h+) A __msdos_initial_alloc_paras$/)
        refute_nil symbol, "#{model}: allocation must be an absolute paragraph count"
        header = File.binread(File.join(@dir, 'output.exe'), 28).unpack('v14')
        initialized_bytes = File.size(File.join(@dir, 'output.exe')) - header[4] * 16
        required_paragraphs = 0x10 + (initialized_bytes + 15) / 16 + header[5]
        assert_equal required_paragraphs, symbol[1].to_i(16),
          "#{model}/#{stack_size || 'default'}: must retain PSP, image, BSS and stack"
      end
    end
  end
def test_far_data_models_align_near_bss_and_common_in_dgroup
  %w[compact large].each do |model|
    [4, 8, 16].each do |alignment|
      File.write(File.join(@dir, 'input.c'), <<~'C')
        volatile unsigned short word[2] = {1, 2};
        int _start(void) { return word[0] + word[1]; }
      C
      File.write(File.join(@dir, 'near.s'), <<~ASM)
        .section .bss.near_alignment,"aw",@nobits
        .balign #{alignment}
        .globl near_bss
      near_bss:
        .space 4
        .comm near_common,4,#{alignment}
      ASM
      run_command(TOOLS / 'clang', '--target=ia16-pc-msdos', '-march=8086',
        "-mmemory-model=#{model}", '-ffreestanding', '-c', 'input.c', '-o', 'input.o')
      run_command(TOOLS / 'clang', '--target=ia16-pc-msdos', '-march=8086',
        "-mmemory-model=#{model}", '-c', 'near.s', '-o', 'near.o')
      symbols, = run_command(TOOLS / 'llvm-nm', '--defined-only', 'near.o')
      assert_match(/^\h+ B near_bss$/, symbols)
      assert_match(/^\h+ C near_common$/, symbols)
      _, stderr = run_command(TOOLS / 'ld.lld', '-m', 'elf_ia16', '--oformat=mz',
        '-T', 'dos.ld', 'input.o', 'near.o', '-o', 'output.exe', '--Map=output.map')
      refute_match(/alignment/, stderr, "#{model}/#{alignment}: linker warning")
      map = File.read(File.join(@dir, 'output.map'))
      section = lambda do |name|
        line = map.lines.find { |entry| entry.match?(/\s#{Regexp.escape(name)}\s*$/) }
        refute_nil line, "#{model}: missing #{name}"
        line.split.first(3).map { |value| value.to_i(16) }
      end
      data, bss = %w[.data .bss].map { |name| section.call(name) }
      %w[near_bss near_common].each do |name|
        line = map.lines.find { |entry| entry.match?(/\s#{name}$/) }
        refute_nil line, "#{model}: missing #{name}"
        vma, lma = line.split.first(2).map { |value| value.to_i(16) }
        assert_operator vma, :>=, bss[0], "#{model}: #{name} below DGROUP BSS"
        assert_operator vma + 4, :<=, bss[0] + bss[2], "#{model}: #{name} outside DGROUP BSS"
        assert_equal 0, vma % alignment, "#{model}: #{name} VMA"
        assert_equal data[1] + vma - data[0], lma, "#{model}: #{name} DGROUP LMA"
        assert_equal 0, lma % alignment, "#{model}: #{name} LMA"
      end
    end
  end
end
  def test_static_objects_respect_requested_alignment
    %w[tiny small medium compact large].each do |model|
      [4, 8, 16].product([false, true]).each do |alignment, common|
        script = if model == 'tiny'
          stdout, = run_command('sh', IA16 / 'dos-mt.ld.in', '-nostdlib', '-mclang-runtime')
          stdout
        else
          IA16ClangSysroot.dos_clang_mz_script((IA16 / 'dos-clang-mz.ld.in').read)
        end
        File.write(File.join(@dir, 'dos.ld'), script)
        File.write(File.join(@dir, 'input.c'), <<~C)
          volatile unsigned short word[2] = {1, 2};
          volatile unsigned long initialized __attribute__((aligned(#{alignment}))) = 3;
          volatile unsigned long datum __attribute__((aligned(#{alignment})));
          int _start(void) { datum = word[0] + word[1] + initialized; return (int)datum; }
        C
        run_command(TOOLS / 'clang', '--target=ia16-pc-msdos', '-march=8086',
          "-mmemory-model=#{model}", '-ffreestanding',
          (common ? '-fcommon' : '-fno-common'), '-c', 'input.c', '-o', 'input.o')
        if common
          symbols, = run_command(TOOLS / 'llvm-nm', '--defined-only', 'input.o')
          assert_match(/^\h+ C datum$/, symbols, "#{model}: fixture must emit COMMON")
        end
        format = model == 'tiny' ? 'binary' : 'mz'
        _, stderr = run_command(TOOLS / 'ld.lld', '-m', 'elf_ia16', "--oformat=#{format}",
          '-T', 'dos.ld', 'input.o', '-o', 'output.exe', '--Map=output.map')
        refute_match(/alignment/, stderr, "#{model}/#{alignment}: linker warning")
        map = File.read(File.join(@dir, 'output.map'))
        %w[initialized datum].each do |name|
          line = map.lines.find { |entry| entry.match?(/\s#{name}$/) }
          refute_nil line, "#{model}/#{alignment}: missing #{name}"
          vma, lma = line.split.first(2).map { |value| value.to_i(16) }
          assert_equal 0, vma % alignment, "#{model}/#{alignment}: #{name} VMA"
          assert_equal 0, lma % alignment, "#{model}/#{alignment}: #{name} LMA"
        end
        unless model == 'tiny'
          section = lambda do |name|
            line = map.lines.find { |entry| entry.match?(/\s#{Regexp.escape(name)}\s*$/) }
            refute_nil line, "#{model}: missing #{name}"
            line.split.first(3).map { |value| value.to_i(16) }
          end
          data, bss, stack = %w[.data .bss .stack].map { |name| section.call(name) }
          assert_operator bss[0], :>=, data[0] + data[2], model
          assert_equal data[1] + bss[0], bss[1], "#{model}: BSS load offset"
          assert_operator stack[0], :>=, bss[0] + bss[2], model
          assert_equal 0, stack[0] % 16, model
          assert_operator stack[0] + stack[2], :<=, 0x10000, model
        end
      end
    end
  end
  def test_multiple_far_functions_spill_without_per_function_build_flags
    %w[medium large].each do |model|
      map = build(model, <<~'C')
        __attribute__((used,noinline)) int a(int x) { __asm__ volatile("jmp 1f\n.fill 24000,1,0x90\n1:"); return x+1; }
        __attribute__((used,noinline)) int b(int x) { __asm__ volatile("jmp 1f\n.fill 24000,1,0x90\n1:"); return x+2; }
        __attribute__((used,noinline)) int c(int x) { __asm__ volatile("jmp 1f\n.fill 24000,1,0x90\n1:"); return x+3; }
        int (*volatile callback)(int) = c;
        int _start(void) { return a(20) + callback(b(17)); }
      C
      assert_operator File.size(File.join(@dir, 'output.exe')), :>, 65_536, model
      nonempty = map.lines.filter_map do |line|
        match = line.match(/^\s*[0-9a-f]+\s+[0-9a-f]+\s+([0-9a-f]+)\s+\d+\s+\.fartext\.\d+\s*$/)
        match && match[1].to_i(16)
      end.count(&:positive?)
      assert_operator nonempty, :>=, 2, model
    end
  end
  def test_first_near_data_object_has_a_nonnull_address
    %w[small medium].each do |model|
      map = build(model, <<~'C')
        int first_object = 7;
        int _start(void) { return first_object; }
      C
      line = map.lines.find { |entry| entry.match?(/\sfirst_object$/) }
      refute_nil line, "#{model}: first object"
      assert_operator line.split[0].to_i(16), :>, 0,
        "#{model}: a valid near-data object cannot have the null pointer address"
    end
  end
  def test_full_segment_far_objects_keep_every_addressable_byte
    %w[compact large].each do |model|
      [false, true].each do |initialized|
        suffix = initialized ? ' = {[65535] = 42}' : ''
        map = build(model, "unsigned long neighbor __attribute__((aligned(8))) = 1; volatile unsigned char full[65536]#{suffix}; int _start(void) { return full[65535] + neighbor; }\n")
        line = map.lines.find { |entry| entry.match?(/\sfull$/) }
        refute_nil line, "#{model}: full segment object"
        assert_equal 0, line.split[0].to_i(16), 'full object must start at segment offset zero'
        header_size = File.binread(File.join(@dir, 'output.exe'), 10).unpack('v*')[4] * 16
        bytes = File.binread(File.join(@dir, 'output.exe'), 65_536, header_size + line.split[1].to_i(16))
        assert_equal "\0" * 65_535 + (initialized ? '*' : "\0"), bytes
      end
    end
  end
  def test_far_object_larger_than_one_segment_is_rejected
    File.write(File.join(@dir, 'input.c'), 'unsigned char oversized[65537]; int _start(void) { return oversized[0]; }')
    run_command(TOOLS / 'clang', '--target=ia16-pc-msdos', '-march=8086', '-mmemory-model=compact',
      '-ffreestanding', '-Oz', '-c', 'input.c', '-o', 'input.o')
    _, stderr, status = Open3.capture3((TOOLS / 'ld.lld').to_s, '-m', 'elf_ia16', '--oformat=mz',
      '-T', 'dos.ld', 'input.o', '-o', 'output.exe', chdir: @dir)
    refute status.success?, 'one object cannot cross a segment boundary'
    assert_includes stderr, 'will not fit'
  end
  def test_far_bss_and_initialized_data_live_outside_dgroup_in_separate_banks
    %w[compact large].each do |model|
      map = build(model, <<~'C')
        volatile unsigned char a[40000] = {1};
        volatile unsigned char b[40000];
        int _start(void) { b[39999] = a[0]; return b[39999]; }
      C
      assert_operator File.size(File.join(@dir, 'output.exe')), :>, 80_000, model
      symbols = %w[a b].map do |name|
        line = map.lines.find { |entry| entry.match?(/\s#{name}$/) }
        refute_nil line, "#{model}: missing #{name}"
        line.split[1].to_i(16)
      end
      assert_operator (symbols[0] - symbols[1]).abs, :>=, 40_000
      header_size = File.binread(File.join(@dir, 'output.exe'), 10).unpack('v*')[4] * 16
      File.open(File.join(@dir, 'output.exe'), 'rb') do |image|
        image.seek(header_size + symbols[1])
        assert_equal "\0" * 40_000, image.read(40_000), "#{model}: far BSS must load zeroed"
      end
    end
  end
end
