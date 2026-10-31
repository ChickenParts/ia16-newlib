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
