#!/usr/bin/env ruby
require 'minitest/autorun'
require 'open3'
require 'pathname'
class IA16InstalledProvidersTest < Minitest::Test
  INSTALL = Pathname(ENV.fetch('IA16_DOS_INSTALL'))
  NM = Pathname(ENV.fetch('IA16_LLVM_BIN')) / 'llvm-nm'
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
      dos = symbols(lib / "libdos-#{letter}.a")
      %w[_read_r _write_r _close_r _isatty_r _lseek_r _mkdir_r _unlink_r _rename_r chdir rmdir].each do |name|
        assert_equal 1, dos.count { |line| line.match?(/ T #{name}$/) }, "#{model}: #{name} provider"
      end
      %w[environ __argv].each do |name|
        definition = dos.find { |line| line.match?(/ C #{name}$/) }
        refute_nil definition, "#{model}: #{name} definition"
        assert_equal (%w[compact large].include?(model) ? 4 : 2), definition.split[-3].to_i(16), "#{model}: #{name} pointer width"
      end
    end
  end
end
