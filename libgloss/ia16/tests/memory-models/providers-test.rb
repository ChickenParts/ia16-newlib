#!/usr/bin/env ruby
require 'minitest/autorun'
require 'open3'
require 'pathname'
class IA16InstalledProvidersTest < Minitest::Test
  INSTALL = Pathname(ENV.fetch('IA16_DOS_INSTALL'))
  NM = Pathname(ENV.fetch('IA16_LLVM_BIN')) / 'llvm-nm'
  OBJDUMP = Pathname(ENV.fetch('IA16_LLVM_BIN')) / 'llvm-objdump'
  MODELS = {'tiny'=>'t', 'small'=>'s', 'medium'=>'m', 'compact'=>'c', 'large'=>'l'}.freeze
  def symbols(archive)
    stdout, stderr, status = Open3.capture3(NM.to_s, '-A', '--defined-only', archive.to_s)
    assert status.success?, stderr
    stdout.lines
  end
  def test_unique_model_correct_providers
    MODELS.each do |model, letter|
      lib = INSTALL / 'ia16-pc-msdos' / model / 'lib'
      libc = symbols(lib / 'libc.a')
      %w[memcpy memset memcmp memmove strlen strcmp strcpy strchr memccpy memrchr rawmemchr].each do |name|
        assert_equal 1, libc.count { |line| line.match?(/ [TDB] #{name}$/) }, "#{model}: #{name} has ambiguous strong providers"
      end
      refute libc.any? { |line| line.match?(/ [DB] environ$/) }, "#{model}: generic environ overrides the CRT environment"
      %w[abort getpid].each do |name|
        refute libc.any? { |line| line.match?(/ T #{name}$/) }, "#{model}: generic #{name} overrides its DOS provider"
      end
      dos = symbols(lib / "libdos-#{letter}.a")
      math = symbols(lib / 'libm.a')
      strong = (libc + math + dos).filter_map { |line| line[/\b[TDBR] (\S+)$/, 1] }
      duplicates = strong.reject { |name| name.end_with?('!', '&') }.tally.select { |_, count| count > 1 }
      assert_empty duplicates, "#{model}: strong providers conflict under whole-archive linking"
      %w[_read_r _write_r _close_r _isatty_r _lseek_r _mkdir_r _unlink_r _rename_r chdir rmdir dup dup2 abort getpid].each do |name|
        assert_equal 1, dos.count { |line| line.match?(/ T #{name}$/) }, "#{model}: #{name} provider"
      end
      %w[environ __argv].each do |name|
        definition = dos.find { |line| line.match?(/ C #{name}$/) }
        refute_nil definition, "#{model}: #{name} definition"
        assert_equal (%w[compact large].include?(model) ? 4 : 2), definition.split[-3].to_i(16), "#{model}: #{name} pointer width"
      end
    end
  end
  def test_assembly_stack_arguments_use_ss
    MODELS.each do |model, letter|
      archive = INSTALL / 'ia16-pc-msdos' / model / 'lib' / "libdos-#{letter}.a"
      stdout, stderr, status = Open3.capture3(OBJDUMP.to_s, '--triple=ia16-none-elf', '-d', archive.to_s)
      assert status.success?, stderr
      routine = stdout.split('<__msdos_dbcs_lead_byte_p>:', 2).last&.split("\n\n", 2)&.first
      refute_nil routine, "#{model}: DBCS provider"
      assert_equal 3, routine.lines.count { |line| line.include?('%ss:') },
        "#{model}: all three DBCS stack arguments require SS"
      if %w[compact large].include?(model)
        rename = stdout.split('<_rename_r>:', 2).last&.split("\n\n", 2)&.first
        refute_nil rename, "#{model}: rename provider"
        before_interrupt = rename.split(/\bint\s+\$0x21/, 2).first
        assert_match(/movw\s+%\w+, %es/, before_interrupt,
          "#{model}: rename must load its destination selector into ES")
      end
    end
  end
end
