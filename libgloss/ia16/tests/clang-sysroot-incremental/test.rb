# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'

require_relative '../../tools/rebuild-clang-cpu-classifier'

class IA16RuntimeRebuilderTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir('ia16-runtime-rebuild-', '/mnt/build/llvm')
  end

  def teardown
    FileUtils.remove_entry(@directory) if @directory && File.directory?(@directory)
  end

  def test_refuses_to_overwrite_a_published_prefix
    existing = File.join(@directory, 'published')
    FileUtils.mkdir_p(existing)

    error = assert_raises(IA16RuntimeRebuilder::Error) do
      IA16RuntimeRebuilder.ensure_new_prefix!(existing)
    end
    assert_match(/already exists/, error.message)
    assert_equal File.join(@directory, 'new'),
      IA16RuntimeRebuilder.ensure_new_prefix!(File.join(@directory, 'new'))
  end

  def test_detects_when_an_object_no_longer_matches_its_archived_member
    objects = File.join(@directory, 'objects')
    FileUtils.mkdir_p(objects)
    File.binwrite(File.join(objects, 'first.o'), "\x7fELF\xfffixture one\n".b)
    File.binwrite(File.join(objects, 'second.o'), "\x7fELF\xfefixture two\n".b)
    archive = File.join(@directory, 'libdos-fixture.a')
    _stdout, stderr, status = Open3.capture3('/usr/bin/ar', 'rcs', archive,
      'first.o', 'second.o', chdir: objects)
    assert status.success?, stderr

    members = IA16RuntimeRebuilder.verify_archive_members!(archive, objects,
      expected_members: %w[first.o second.o])
    assert_equal %w[first.o second.o], members.map { |member| member.fetch('name') }
    assert_equal 2, members.length
    assert IA16RuntimeRebuilder.verify_archive_contents!(archive,
      %w[first.o second.o].map { |name| File.join(objects, name) },
      expected_names: %w[first.o second.o])

    File.binwrite(File.join(objects, 'second.o'), "\x7fELF\xfdchanged fixture\n".b)
    error = assert_raises(IA16RuntimeRebuilder::Error) do
      IA16RuntimeRebuilder.verify_archive_members!(archive, objects,
        expected_members: %w[first.o second.o])
    end
    assert_match(/does not match archive member/, error.message)
  end

  def test_relocated_profiles_use_the_selected_prefix_and_toolchain_only
    old_prefix = '/mnt/build/ia16-dos-runtime-old'
    new_prefix = '/mnt/build/ia16-dos-runtime-new'
    old_tools = '/mnt/build/ia16-tools-old'
    new_tools = '/mnt/build/llvm/handoffs/ia16-current'
    profile = "clang=#{old_tools}/bin/clang\nlib=#{old_prefix}/ia16-pc-msdos/lib\n"

    relocated = IA16RuntimeRebuilder.relocate_profile_paths!(profile,
      old_prefix: old_prefix, new_prefix: new_prefix,
      old_tool_root: old_tools, new_tool_root: new_tools)

    assert_includes relocated, "clang=#{new_tools}/bin/clang"
    assert_includes relocated, "lib=#{new_prefix}/ia16-pc-msdos/lib"
    refute_includes relocated, old_prefix
    refute_includes relocated, old_tools
  end

  def test_checks_all_non_whitelisted_staged_files_are_unchanged
    baseline = File.join(@directory, 'baseline')
    candidate = File.join(@directory, 'candidate')
    [baseline, candidate].each do |root|
      FileUtils.mkdir_p(File.join(root, 'ia16-pc-msdos/lib'))
      FileUtils.mkdir_p(File.join(root, 'ia16-pc-msdos/include'))
      File.binwrite(File.join(root, 'ia16-pc-msdos/lib/libc.a'), "libc fixture\n")
      File.binwrite(File.join(root, 'ia16-pc-msdos/lib/dos-s-c0.o'), "startup fixture\n")
      File.binwrite(File.join(root, 'ia16-pc-msdos/include/stdio.h'), "header fixture\n")
      File.binwrite(File.join(root, 'ia16-pc-msdos/lib/libdos-s.a'), "archive fixture\n")
    end
    File.binwrite(File.join(candidate, 'ia16-pc-msdos/lib/libdos-s.a'), "updated archive\n")
    changed = ['ia16-pc-msdos/lib/libdos-s.a']

    assert IA16RuntimeRebuilder.verify_unchanged_files!(baseline, candidate,
      allowed_changes: changed)
    File.binwrite(File.join(candidate, 'ia16-pc-msdos/include/stdio.h'), "changed header\n")
    error = assert_raises(IA16RuntimeRebuilder::Error) do
      IA16RuntimeRebuilder.verify_unchanged_files!(baseline, candidate,
        allowed_changes: changed)
    end
    assert_match(/unexpected staged file changes/, error.message)
  end

  def test_compile_arguments_only_use_explicit_current_tool_paths
    tool_root = File.join(@directory, 'current-toolchain')
    resource_dir = File.join(tool_root, 'lib/clang/24')
    source_root = File.join(@directory, 'source')
    baseline_build = File.join(@directory, 'baseline-build')
    source = File.join(source_root, 'libgloss/ia16/dos-uname-impl.S')
    output = File.join(@directory, 'new-object/dos-uname-impl.o')

    args = IA16RuntimeRebuilder.compile_argv(compiler: File.join(tool_root, 'bin/clang-24'),
      source_file: source, source_root: source_root, baseline_build: baseline_build,
      tool_root: tool_root, resource_dir: resource_dir, output_path: output)

    assert_includes args, '--target=ia16-pc-msdos'
    assert_includes args, "#{resource_dir}/include"
    assert_includes args, source
    assert_includes args, output
    refute_includes args.join(' '), '/mnt/build/ia16-tools-9e816ba3'
  end

  def test_generated_ninja_graph_parses_with_separate_stage_and_seal_targets
    source = File.join(@directory, 'source/dos-uname-impl.S')
    header = File.join(@directory, 'source/call-cvt.h')
    old_object = File.join(@directory, 'old-build/other.o')
    plan = {
      'object_output' => 'obj/dos-uname-impl.o',
      'source_file' => source,
      'source_header' => header,
      'compile_command' => 'true -c source.S -o obj/dos-uname-impl.o',
      'archive_outputs' => {
        'libdos-s.a' => 'archives/libdos-s.a',
        'libdos-t.a' => 'archives/libdos-t.a',
      },
      'archive_inputs' => {
        'libdos-s.a' => ['obj/dos-uname-impl.o', old_object],
        'libdos-t.a' => ['obj/dos-uname-impl.o', old_object],
      },
      'archive_commands' => {
        'libdos-s.a' => 'true --archive-small',
        'libdos-t.a' => 'true --archive-tiny',
      },
      'builtins_file' => File.join(@directory, 'tool/libclang_rt.builtins-ia16.a'),
      'stage_command' => 'true --stage',
      'seal_command' => 'true --seal',
      'plan_file' => 'rebuild-plan.json',
      'acceptance_file' => 'vm-acceptance.json',
      'stage_stamp' => 'candidate-stage.stamp',
      'profile_file' => 'build-profile.json',
      'sealed_file' => 'sealed.json',
    }
    File.write(File.join(@directory, 'build.ninja'),
      IA16RuntimeRebuilder.render_ninja(plan))

    stdout, stderr, status = Open3.capture3('ninja', '-C', @directory, '-t', 'targets')

    assert status.success?, stdout + stderr
    assert_includes stdout, 'stage-candidate'
    assert_includes stdout, 'seal'
    ninja_text = File.read(File.join(@directory, 'build.ninja'))
    assert_includes ninja_text, 'default stage-candidate'
    assert_includes ninja_text, 'vm-acceptance.json'
  end
end
