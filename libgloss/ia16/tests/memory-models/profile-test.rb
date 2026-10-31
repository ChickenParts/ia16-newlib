#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require 'pathname'
require_relative '../../tools/build-clang-sysroot'

class IA16DriverProfilesTest < Minitest::Test
  def test_tiny_script_keeps_crt_fallthrough_sections_during_gc
    template = Pathname(__dir__) / '../../dos-mt.ld.in'
    script, error, status = Open3.capture3('sh', template.to_s, '-nostdlib', '-mclang-runtime')
    assert status.success?, error
    %w[startupA startupB startupC startupD startupE startupF head msdos_init msdos_initA
       msdos_initB preinit init exitA fini exitB].each do |section|
      assert_match(/KEEP\s*\(\*\(\.#{section}(?:\s|\))/, script,
                   "#{section} must survive GC: CRT falls through between sections")
    end
  end

  def test_profiles_use_driver_runtime_selection_and_query_for_direct_links
    Dir.mktmpdir('ia16-profiles-') do |directory|
      root = Pathname(directory)
      builder = IA16ClangSysroot::Builder.allocate
      { install: root, clang: root / 'tools/bin/clang', ld: root / 'tools/bin/ld.lld',
        resource_dir: root / 'tools/lib/clang/24', builtins_root: root / 'builtins',
        manifest: { 'models' => IA16ClangSysroot::MODELS.keys.to_h { |model| [model.to_s, {}] } }
      }.each { |name, value| builder.instance_variable_set("@#{name}", value) }
      builder.send(:write_profiles)
      profile = (root / 'profile.sh').read
      IA16ClangSysroot::MODELS.each_key do |model|
        link = profile[/ia16_link_#{model}\(\) \{\n(.*?)\n\}/m, 1]
        assert_includes link, '-femulated-tls', "#{model}: LTO must preserve the TLS runtime policy"
        refute_includes link, '-nostdlib', "#{model}: normal links must exercise driver lookup"
        refute_includes link, 'libclang_rt.builtins', "#{model}: archive must be selected by Clang"
        assert_includes link, model == :tiny ? '-Wl,--oformat\=binary' : '-Wl,--oformat\=mz'
        assert_includes link, '-resource-dir', "#{model}: select the supplied builtins installation"
        direct = profile[/ia16_direct_link_#{model}\(\) \{\n(.*?)\n\}/m, 1]
        assert_includes direct, '-plugin-opt\=-emulated-tls'
        assert_includes direct, '--print-libgcc-file-name', "#{model}: direct link must query the matching archive"
        assert_includes direct, "mmemory-model\\=#{model}"
        compile = profile[/ia16_clang_#{model}\(\) \{\n(.*?)\n\}/m, 1]
        assert_includes compile, '-ffunction-sections'
        assert_includes compile, '-fdata-sections'
      end
    end
  end
end
