#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require 'pathname'
require_relative '../../tools/build-clang-sysroot'

class IA16DriverProfilesTest < Minitest::Test
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
        refute_includes link, '-nostdlib', "#{model}: normal links must exercise driver lookup"
        refute_includes link, 'libclang_rt.builtins', "#{model}: archive must be selected by Clang"
        assert_includes link, model == :tiny ? '-Wl,--oformat\=binary' : '-Wl,--oformat\=mz'
        assert_includes link, '-resource-dir', "#{model}: select the supplied builtins installation"
        direct = profile[/ia16_direct_link_#{model}\(\) \{\n(.*?)\n\}/m, 1]
        assert_includes direct, '--print-libgcc-file-name', "#{model}: direct link must query the matching archive"
        assert_includes direct, "mmemory-model\\=#{model}"
        compile = profile[/ia16_clang_#{model}\(\) \{\n(.*?)\n\}/m, 1]
        assert_includes compile, '-ffunction-sections'
        assert_includes compile, '-fdata-sections'
      end
    end
  end
end
