# Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'open3'
require 'optparse'
require 'rbconfig'
require 'shellwords'
require 'set'

module IA16RuntimeRebuilder
  class Error < StandardError; end

  BASELINE_SOURCE_COMMIT = 'f0add853331c830ecf0d14d107f6b51e4a0abb13'
  BASELINE_BUILD = '/mnt/build/ia16-dos-runtime-f0add85-build'
  BASELINE_PREFIX = '/mnt/build/ia16-dos-runtime-f0add85'
  BASELINE_SOURCE = '/mnt/build/ia16-dos-runtime-f0add85-source'
  TARGET = 'ia16-pc-msdos'
  SMALL_SCRIPT_TEMPLATE = 'libgloss/ia16/dos-mx.ld.in'
  SMALL_SCRIPT_OUTPUT = File.join(TARGET, 'lib', 'dos-clang-small.ld')
  ARCHIVE_NAMES = %w[libdos-s.a libdos-t.a].freeze
  REPLACED_OBJECT = 'dos-uname-impl.o'
  EXPECTED_ARCHIVE_MEMBERS = 46
  BUILTINS_NAME = 'libclang_rt.builtins-ia16.a'
  OLD_TOOL_ROOT = '/mnt/build/ia16-tools-9e816ba3'

  module_function

  def sha256(path)
    Digest::SHA256.file(path).hexdigest
  end

  def tree_sha256(root)
    root = File.expand_path(root)
    digest = Digest::SHA256.new
    Find.find(root).sort.each do |path|
      next if path == root
      relative = path.delete_prefix("#{root}/")
      if File.symlink?(path)
        digest << "L\0#{relative}\0#{File.readlink(path)}\0"
      elsif File.file?(path)
        digest << "F\0#{relative}\0#{sha256(path)}\0"
      end
    end
    digest.hexdigest
  end

  def ensure_new_prefix!(path)
    expanded = File.expand_path(path)
    raise Error, "install prefix already exists: #{expanded}" if File.exist?(expanded)
    expanded
  end

  def capture!(*argv, chdir: nil)
    stdout, stderr, status = if chdir
                               Open3.capture3(*argv, chdir: chdir)
                             else
                               Open3.capture3(*argv)
                             end
    return stdout.b if status.success?
    raise Error, "command failed (#{status.exitstatus}): #{Shellwords.join(argv)}\n#{stderr}"
  rescue Errno::ENOENT => e
    raise Error, "cannot run #{argv.first}: #{e.message}"
  end

  def verify_archive_members!(archive, object_dir, expected_members: nil,
                              ar: '/usr/bin/ar')
    names = capture!(ar, 't', archive).lines.map(&:chomp)
    if expected_members && names != expected_members
      raise Error, "archive member order differs from baseline in #{archive}"
    end
    if names.uniq.length != names.length
      raise Error, "archive contains duplicate member names: #{archive}"
    end
    names.map do |name|
      object = File.join(object_dir, name)
      raise Error, "baseline object is missing: #{object}" unless File.file?(object)
      archived = capture!(ar, 'p', archive, name)
      unless File.binread(object) == archived
        raise Error, "baseline object does not match archive member #{name}: #{archive}"
      end
      { 'name' => name, 'path' => object, 'sha256' => sha256(object) }
    end
  end

  def verify_archive_contents!(archive, input_paths, expected_names:, ar: '/usr/bin/ar')
    names = capture!(ar, 't', archive).lines.map(&:chomp)
    unless names == expected_names
      raise Error, "rebuilt archive member order differs from the pinned baseline: #{archive}"
    end
    raise Error, "rebuilt archive contains duplicate members: #{archive}" if names.uniq.length != names.length
    unless input_paths.length == names.length
      raise Error, "rebuilt archive input count differs from its member count: #{archive}"
    end
    names.zip(input_paths).each do |name, path|
      raise Error, "rebuilt archive input is missing: #{path}" unless File.file?(path)
      archived = capture!(ar, 'p', archive, name)
      unless archived == File.binread(path)
        raise Error, "rebuilt archive member differs from input #{path}: #{name}"
      end
    end
    true
  end

  def relocate_profile_paths!(text, old_prefix:, new_prefix:, old_tool_root:, new_tool_root:)
    replaced = text.gsub(old_prefix, new_prefix).gsub(old_tool_root, new_tool_root)
    if replaced.include?(old_prefix) || replaced.include?(old_tool_root)
      raise Error, 'active profile still refers to the baseline prefix or toolchain'
    end
    replaced
  end

  def file_inventory(root)
    root = File.expand_path(root)
    inventory = {}
    Find.find(root) do |path|
      next if path == root || File.directory?(path)
      relative = path.delete_prefix("#{root}/")
      inventory[relative] = if File.symlink?(path)
                              "link:#{File.readlink(path)}"
                            else
                              sha256(path)
                            end
    end
    inventory
  end

  def verify_unchanged_files!(baseline, candidate, allowed_changes:)
    allowed = allowed_changes.map { |path| path.sub(%r{\A\./}, '') }.to_set
    before = file_inventory(baseline)
    after = file_inventory(candidate)
    changed = (before.keys | after.keys).select { |name| before[name] != after[name] }
    unexpected = changed.reject { |name| allowed.include?(name) }
    unless unexpected.empty?
      raise Error, "unexpected staged file changes: #{unexpected.sort.join(', ')}"
    end
    absent = allowed.select { |name| !after.key?(name) }
    unless absent.empty?
      raise Error, "expected replacement files are absent: #{absent.sort.join(', ')}"
    end
    true
  end

  def small_script_plan(source_root)
    template = File.join(File.expand_path(source_root), SMALL_SCRIPT_TEMPLATE)
    raise Error, "small-model linker script template is missing: #{template}" unless File.file?(template)
    {
      'small_script_template' => template,
      'small_script_template_sha256' => sha256(template),
      'small_script_generator_argv' => ['sh', template, '-nostdlib', '-mclang-runtime'],
      'small_script_output_relative_path' => SMALL_SCRIPT_OUTPUT
    }
  end

  def validate_small_script_plan!(plan)
    expected_template = File.join(File.expand_path(plan.fetch('source_root')), SMALL_SCRIPT_TEMPLATE)
    unless plan.fetch('small_script_template') == expected_template
      raise Error, 'small-model linker script template path differs from the selected source tree'
    end
    unless plan.fetch('small_script_output_relative_path') == SMALL_SCRIPT_OUTPUT
      raise Error, 'small-model linker script output path differs from the maintained prefix path'
    end
    true
  end

  def generate_small_linker_script!(template:, expected_sha256:, generator_argv:, output_path:)
    template = File.expand_path(template)
    raise Error, "small-model linker script template is missing: #{template}" unless File.file?(template)
    unless sha256(template) == expected_sha256
      raise Error, "small-model linker script template changed after plan generation: #{template}"
    end
    expected_argv = ['sh', template, '-nostdlib', '-mclang-runtime']
    unless generator_argv == expected_argv
      raise Error, 'small-model linker script generator argv differs from the pinned command'
    end
    output = capture!(*generator_argv)
    FileUtils.mkdir_p(File.dirname(output_path))
    File.binwrite(output_path, output)
    {
      'source_template' => template,
      'source_template_sha256' => expected_sha256,
      'generator_argv' => generator_argv,
      'output_path' => File.expand_path(output_path),
      'output_sha256' => sha256(output_path)
    }
  end

  def compile_argv(compiler:, source_file:, source_root:, baseline_build:, tool_root:,
                   resource_dir:, output_path:)
    source_root = File.expand_path(source_root)
    baseline_build = File.expand_path(baseline_build)
    tool_root = File.expand_path(tool_root)
    unless File.expand_path(compiler).start_with?("#{tool_root}/") &&
           File.expand_path(resource_dir).start_with?("#{tool_root}/")
      raise Error, 'compiler and resource headers must come from the selected tool root'
    end
    objdir = File.join(baseline_build, TARGET, 'libgloss/ia16')
    newlib_build = File.join(baseline_build, TARGET, 'newlib')
    source_libgloss = File.join(source_root, 'libgloss/ia16')
    source_newlib = File.join(source_root, 'newlib/libc/include')
    [
      compiler,
      '--target=ia16-pc-msdos', '-march=8086', '-mmemory-model=small', '-nostdinc',
      '-I', File.join(newlib_build, 'targ-include'), '-I', source_newlib,
      '-isystem', File.join(newlib_build, 'targ-include'), '-isystem', source_newlib,
      '-isystem', File.join(resource_dir, 'include'),
      "-B#{newlib_build}/", '-isystem', File.join(newlib_build, 'targ-include'),
      '-isystem', source_newlib,
      "-B#{objdir}", "-L#{File.join(baseline_build, TARGET, 'libgloss/libnosys')}",
      "-L#{source_libgloss}",
      '-std=gnu17', '-Oz', '-femulated-tls', '-ffreestanding', '-fno-builtin', '-nostdinc',
      '-I.', "-I#{File.join(source_libgloss, '..')}", '-I./..',
      '-idirafter', File.join(source_root, 'include'), "-I#{source_libgloss}",
      '-I.', "-I#{File.join(source_libgloss, '..')}", '-I../libnosys',
      '-std=gnu17', '-Oz', '-femulated-tls', '-ffreestanding', '-fno-builtin', '-nostdinc',
      '-c', source_file, '-o', output_path
    ]
  end

  def ninja_escape(value)
    value.to_s.gsub('$', '$$').gsub(' ', '$ ').gsub(':', '$:')
  end

  def render_ninja(plan)
    object = plan.fetch('object_output')
    source = plan.fetch('source_file')
    deps = plan.fetch('source_headers', [plan['source_header']].compact)
    deps += plan.fetch('compile_implicit_inputs', [])
    lines = [
      'ninja_required_version = 1.7',
      'rule run_command',
      '  command = $cmd',
      '  description = $description',
      ''
    ]
    lines << "build #{ninja_escape(object)}: run_command #{ninja_escape(source)}" +
      (deps.empty? ? '' : " | #{deps.map { |dep| ninja_escape(dep) }.join(' ')}")
    lines << "  cmd = #{ninja_escape(plan.fetch('compile_command'))}"
    lines << '  description = compile fixed IA16 runtime assembly'
    plan.fetch('archive_outputs').each do |name, output|
      inputs = plan.fetch('archive_inputs').fetch(name)
      lines << "build #{ninja_escape(output)}: run_command #{inputs.map { |path| ninja_escape(path) }.join(' ')}"
      lines << "  cmd = #{ninja_escape(plan.fetch('archive_commands').fetch(name))}"
      lines << "  description = rebuild #{name} from verified baseline objects"
    end
    stage_stamp = plan.fetch('stage_stamp')
    builtins = plan.fetch('builtins_file')
    stage_inputs = plan.fetch('archive_outputs').values + [builtins]
    if plan.fetch('regenerate_small_linker_script', false)
      stage_inputs << plan.fetch('small_script_template')
    end
    lines << "build #{ninja_escape(stage_stamp)}: run_command " +
      stage_inputs.map { |path| ninja_escape(path) }.join(' ')
    lines << "  cmd = #{ninja_escape(plan.fetch('stage_command'))}"
    lines << '  description = stage incremental candidate prefix'
    lines << "build stage-candidate: phony #{ninja_escape(stage_stamp)}"
    sealed = plan.fetch('sealed_file')
    acceptance = plan.fetch('acceptance_file')
    lines << "build #{ninja_escape(sealed)}: run_command #{ninja_escape(acceptance)} #{ninja_escape(stage_stamp)}"
    lines << "  cmd = #{ninja_escape(plan.fetch('seal_command'))}"
    lines << '  description = seal only after external VM acceptance'
    lines << "build seal: phony #{ninja_escape(sealed)}"
    lines << 'default stage-candidate'
    lines.join("\n") + "\n"
  end

  def validate_simple_path!(path, label)
    expanded = File.expand_path(path)
    unless expanded.start_with?('/mnt/build/') && !expanded.match?(/[\s\n\r$]/)
      raise Error, "#{label} must be a whitespace-free path under /mnt/build: #{expanded}"
    end
    expanded
  end

  def paths_overlap?(left, right)
    left = File.expand_path(left)
    right = File.expand_path(right)
    left == right || left.start_with?("#{right}/") || right.start_with?("#{left}/")
  end

  def run_cli(options)
    regenerate_small_linker_script = options.fetch(:regenerate_small_linker_script, false)
    source_root = validate_simple_path!(options.fetch(:source_root), '--source-root')
    baseline_build = validate_simple_path!(options.fetch(:baseline_build), '--baseline-build')
    baseline_prefix = validate_simple_path!(options.fetch(:baseline_prefix), '--baseline-prefix')
    tool_root = validate_simple_path!(options.fetch(:tool_root), '--tool-root')
    build_root = validate_simple_path!(options.fetch(:build_root), '--build-root')
    install_prefix = validate_simple_path!(options.fetch(:install_prefix), '--install-prefix')
    unless baseline_build == BASELINE_BUILD && baseline_prefix == BASELINE_PREFIX
      raise Error, 'baseline inputs must be the pinned f0add85 build and install prefix'
    end
    raise Error, 'new build root must not exist' if File.exist?(build_root)
    ensure_new_prefix!(install_prefix)
    [source_root, tool_root, build_root, install_prefix].each do |path|
      raise Error, "required input does not exist: #{path}" unless File.directory?(path) || path == build_root || path == install_prefix
    end
    outputs = [build_root, install_prefix]
    inputs = [source_root, baseline_build, baseline_prefix, tool_root]
    outputs.combination(2) do |left, right|
      raise Error, 'build root and install prefix must be separate trees' if paths_overlap?(left, right)
    end
    outputs.each do |output|
      inputs.each do |input|
        raise Error, "output path overlaps immutable input: #{output} and #{input}" if paths_overlap?(output, input)
      end
    end

    profile_path = File.join(baseline_build, 'build-profile.json')
    baseline_profile = JSON.parse(File.read(profile_path))
    unless baseline_profile['status'] == 'pass' && baseline_profile['target'] == TARGET &&
           baseline_profile['source_commit'] == BASELINE_SOURCE_COMMIT &&
           File.expand_path(baseline_profile['install_prefix']) == baseline_prefix
      raise Error, 'baseline build profile does not identify the pinned passing f0add85 build'
    end
    if File.expand_path(baseline_profile['source_root']) != BASELINE_SOURCE
      raise Error, 'baseline build profile source root differs from pinned f0add85 source'
    end
    actual_baseline_commit = capture!('git', '-C', BASELINE_SOURCE, 'rev-parse', 'HEAD').strip
    raise Error, 'pinned baseline source checkout is not f0add85' unless actual_baseline_commit == BASELINE_SOURCE_COMMIT

    source_commit = capture!('git', '-C', source_root, 'rev-parse', 'HEAD').strip
    source_status = capture!('git', '-C', source_root, 'status', '--porcelain').strip
    raise Error, 'fixed source checkout must be clean and committed' unless source_status.empty?
    capture!('git', '-C', source_root, 'merge-base', '--is-ancestor', BASELINE_SOURCE_COMMIT, source_commit)
    relative_source = 'libgloss/ia16/dos-uname-impl.S'
    new_source = File.join(source_root, relative_source)
    old_source_text = capture!('git', '-C', source_root, 'show', "#{BASELINE_SOURCE_COMMIT}:#{relative_source}")
    raise Error, 'new dos-uname-impl.S is not changed from pinned baseline' if File.binread(new_source) == old_source_text

    compiler = File.join(tool_root, 'bin/clang')
    linker = File.join(tool_root, 'bin/ld.lld')
    ar = '/usr/bin/ar'
    [compiler, linker, ar].each do |path|
      raise Error, "required tool missing: #{path}" unless File.file?(path) && File.executable?(path)
    end
    compiler_real = File.realpath(compiler)
    unless compiler_real.start_with?("#{File.realpath(tool_root)}/")
      raise Error, 'clang resolves outside the selected tool root'
    end
    resource_dir = capture!(compiler, '-print-resource-dir').strip
    unless File.realpath(resource_dir).start_with?("#{File.realpath(tool_root)}/")
      raise Error, 'clang resource directory resolves outside the selected tool root'
    end
    builtins = capture!(compiler, "--target=#{TARGET}", '-print-file-name=libclang_rt.builtins-ia16.a').strip
    unless File.file?(builtins) && File.realpath(builtins).start_with?("#{File.realpath(tool_root)}/")
      raise Error, 'selected clang did not resolve builtins inside the current tool root'
    end

    object_dir = File.join(baseline_build, TARGET, 'libgloss/ia16')
    expected_lists = {}
    ARCHIVE_NAMES.each do |name|
      baseline_archive = File.join(object_dir, name)
      installed_archive = File.join(baseline_prefix, TARGET, 'lib', name)
      raise Error, "baseline archive missing: #{baseline_archive}" unless File.file?(baseline_archive)
      raise Error, "installed baseline archive differs: #{installed_archive}" unless sha256(baseline_archive) == sha256(installed_archive)
      members = verify_archive_members!(baseline_archive, object_dir)
      raise Error, "expected #{EXPECTED_ARCHIVE_MEMBERS} members in #{name}" unless members.length == EXPECTED_ARCHIVE_MEMBERS
      raise Error, "#{name} must have exactly one #{REPLACED_OBJECT}" unless members.count { |m| m['name'] == REPLACED_OBJECT } == 1
      expected_lists[name] = members
    end
    FileUtils.mkdir_p(build_root)
    object_output = File.join(build_root, 'obj', REPLACED_OBJECT)
    FileUtils.mkdir_p(File.dirname(object_output))
    compile_args = compile_argv(compiler: compiler, source_file: new_source,
      source_root: source_root, baseline_build: baseline_build, tool_root: tool_root,
      resource_dir: resource_dir, output_path: object_output)
    compile_cwd = File.join(baseline_build, TARGET, 'libgloss/ia16')
    archive_outputs = ARCHIVE_NAMES.to_h { |name| [name, File.join(build_root, 'archives', name)] }
    FileUtils.mkdir_p(File.join(build_root, 'archives'))
    archive_inputs = {}
    archive_commands = {}
    expected_lists.each do |name, members|
      inputs = members.map do |member|
        member['name'] == REPLACED_OBJECT ? object_output : member['path']
      end
      archive_inputs[name] = inputs
      archive_commands[name] = Shellwords.join([ar, 'rcs', archive_outputs.fetch(name), *inputs])
    end
    profile_hash = sha256(profile_path)
    plan = {
      'regenerate_small_linker_script' => regenerate_small_linker_script,
      'source_commit' => source_commit,
      'source_root' => source_root,
      'source_file' => new_source,
      'source_headers' => %w[call-cvt.h hw.h].map { |name| File.join(source_root, 'libgloss/ia16', name) },
      'compile_implicit_inputs' => [compiler],
      'source_sha256' => sha256(new_source),
      'baseline_build' => baseline_build,
      'baseline_prefix' => baseline_prefix,
      'baseline_source_commit' => BASELINE_SOURCE_COMMIT,
      'baseline_profile_sha256' => profile_hash,
      'tool_root' => tool_root,
      'compiler' => compiler,
      'compiler_sha256' => sha256(compiler_real),
      'linker' => linker,
      'linker_sha256' => sha256(File.realpath(linker)),
      'resource_dir' => resource_dir,
      'builtins_file' => builtins,
      'builtins_sha256' => sha256(builtins),
      'ar' => ar,
      'object_output' => object_output,
      'compile_argv' => compile_args,
      'compile_cwd' => compile_cwd,
      'compile_command' => "cd #{Shellwords.escape(compile_cwd)} && #{Shellwords.join(compile_args)}",
      'archive_outputs' => archive_outputs,
      'archive_inputs' => archive_inputs,
      'archive_commands' => archive_commands,
      'archive_member_records' => expected_lists,
      'install_prefix' => install_prefix,
      'stage_stamp' => File.join(build_root, 'candidate-stage.stamp'),
      'acceptance_file' => File.join(build_root, 'vm-acceptance.json'),
      'profile_file' => File.join(build_root, 'build-profile.json'),
      'manifest_file' => File.join(build_root, 'candidate-manifest.json'),
      'sealed_file' => File.join(build_root, 'sealed.json'),
      'plan_file' => File.join(build_root, 'rebuild-plan.json'),
      'helper_file' => File.expand_path(__FILE__)
    }
    plan.merge!(small_script_plan(source_root)) if regenerate_small_linker_script
    plan['stage_command'] = Shellwords.join([RbConfig.ruby, plan['helper_file'], '--internal', 'stage', plan['plan_file']])
    plan['seal_command'] = Shellwords.join([RbConfig.ruby, plan['helper_file'], '--internal', 'seal', plan['plan_file']])
    plan['archive_member_records'] = expected_lists.transform_values do |members|
      members.map { |member| { 'name' => member['name'], 'sha256' => member['sha256'] } }
    end
    File.write(plan['plan_file'], JSON.pretty_generate(plan) + "\n")
    File.write(File.join(build_root, 'build.ninja'), render_ninja(plan))
    puts "Generated incremental Ninja plan: #{build_root}"
    puts "Source commit: #{source_commit}"
    puts 'Next: ninja -C <build-root> stage-candidate'
  end

  def run_stage(plan_path)
    plan = JSON.parse(File.read(plan_path))
    prefix = ensure_new_prefix!(plan.fetch('install_prefix'))
    baseline = plan.fetch('baseline_prefix')
    if sha256(File.join(plan.fetch('baseline_build'), 'build-profile.json')) != plan.fetch('baseline_profile_sha256')
      raise Error, 'pinned baseline build profile changed after plan generation'
    end
    ARCHIVE_NAMES.each do |name|
      records = plan.fetch('archive_member_records').fetch(name)
      inputs = plan.fetch('archive_inputs').fetch(name)
      expected_names = records.map { |record| record.fetch('name') }
      unless inputs.length == expected_names.length
        raise Error, "planned inputs do not cover every member of #{name}"
      end
      inputs.zip(records).each do |path, record|
        next if record.fetch('name') == REPLACED_OBJECT
        unless sha256(path) == record.fetch('sha256')
          raise Error, "pinned baseline object changed after plan generation: #{path}"
        end
      end
      verify_archive_contents!(plan.fetch('archive_outputs').fetch(name), inputs,
        expected_names: expected_names)
    end
    FileUtils.mkdir_p(File.dirname(prefix))
    FileUtils.cp_r("#{baseline}/.", prefix, preserve: true)
    ARCHIVE_NAMES.each do |name|
      FileUtils.cp(plan.fetch('archive_outputs').fetch(name),
        File.join(prefix, TARGET, 'lib', name), preserve: true)
    end
    builtins_dst = File.join(prefix, TARGET, 'lib', BUILTINS_NAME)
    FileUtils.cp(plan.fetch('builtins_file'), builtins_dst, preserve: true)

    small_script_record = nil
    if plan.fetch('regenerate_small_linker_script', false)
      validate_small_script_plan!(plan)
      small_script_record = generate_small_linker_script!(
        template: plan.fetch('small_script_template'),
        expected_sha256: plan.fetch('small_script_template_sha256'),
        generator_argv: plan.fetch('small_script_generator_argv'),
        output_path: File.join(prefix, plan.fetch('small_script_output_relative_path')))
    end

    %w[profile.sh header-profile/profile.sh].each do |relative|
      path = File.join(prefix, relative)
      next unless File.file?(path)
      text = File.read(path)
      updated = relocate_profile_paths!(text, old_prefix: baseline,
        new_prefix: prefix, old_tool_root: OLD_TOOL_ROOT, new_tool_root: plan.fetch('tool_root'))
      File.write(path, updated)
    end
    allowed = ARCHIVE_NAMES.map { |name| "#{TARGET}/lib/#{name}" } +
      ["#{TARGET}/lib/#{BUILTINS_NAME}", 'profile.sh', 'header-profile/profile.sh']
    if small_script_record
      allowed << plan.fetch('small_script_output_relative_path')
    end
    verify_unchanged_files!(baseline, prefix, allowed_changes: allowed)

    object_path = File.join(plan.fetch('object_output'))
    archive_hashes = ARCHIVE_NAMES.to_h do |name|
      [name, sha256(File.join(prefix, TARGET, 'lib', name))]
    end
    preserved = {
      'libc.a' => sha256(File.join(prefix, TARGET, 'lib/libc.a')),
      'libg.a' => sha256(File.join(prefix, TARGET, 'lib/libg.a')),
      'startup_dos_s' => sha256(File.join(prefix, TARGET, 'lib/dos-s-c0.o')),
      'startup_dos_t' => sha256(File.join(prefix, TARGET, 'lib/dos-t-c0.o')),
      'startup_dtr_t' => sha256(File.join(prefix, TARGET, 'lib/dtr-t-c0.o')),
      'header_include_tree' => tree_sha256(File.join(prefix, 'header-profile/include'))
    }
    manifest = {
      'status' => 'candidate-staged-qualification-pending',
      'source_commit' => plan.fetch('source_commit'),
      'source_sha256' => plan.fetch('source_sha256'),
      'baseline_source_commit' => plan.fetch('baseline_source_commit'),
      'baseline_profile_sha256' => plan.fetch('baseline_profile_sha256'),
      'tool_root' => plan.fetch('tool_root'),
      'compiler_sha256' => plan.fetch('compiler_sha256'),
      'linker_sha256' => plan.fetch('linker_sha256'),
      'builtins_sha256' => plan.fetch('builtins_sha256'),
      'object_sha256' => sha256(object_path),
      'archive_sha256' => archive_hashes,
      'preserved_sha256' => preserved,
      'install_prefix' => prefix,
      'prefix_tree_sha256' => tree_sha256(prefix),
      'qualification' => 'pending external VM acceptance; this is not a full rebuild or header requalification'
    }
    manifest['regenerated_small_linker_script'] = small_script_record if small_script_record
    File.write(plan.fetch('manifest_file'), JSON.pretty_generate(manifest) + "\n")
    profile = {
      'status' => manifest.fetch('status'),
      'target' => TARGET,
      'source_root' => plan.fetch('source_root'),
      'source_commit' => plan.fetch('source_commit'),
      'source_status' => '',
      'source_file_sha256' => plan.fetch('source_sha256'),
      'build_root' => File.dirname(plan_path),
      'install_prefix' => prefix,
      'baseline' => {
        'source_commit' => plan.fetch('baseline_source_commit'),
        'build_root' => plan.fetch('baseline_build'),
        'install_prefix' => plan.fetch('baseline_prefix'),
        'profile_sha256' => plan.fetch('baseline_profile_sha256')
      },
      'tool_root' => plan.fetch('tool_root'),
      'compiler' => plan.fetch('compiler'),
      'compiler_sha256' => plan.fetch('compiler_sha256'),
      'linker' => plan.fetch('linker'),
      'linker_sha256' => plan.fetch('linker_sha256'),
      'builtins' => plan.fetch('builtins_file'),
      'builtins_sha256' => plan.fetch('builtins_sha256'),
      'compile_argv' => plan.fetch('compile_argv'),
      'object_sha256' => manifest.fetch('object_sha256'),
      'archive_sha256' => archive_hashes,
      'preserved_sha256' => preserved,
      'candidate_manifest_sha256' => sha256(plan.fetch('manifest_file')),
      'qualification' => manifest.fetch('qualification')
    }
    profile['regenerated_small_linker_script'] = small_script_record if small_script_record
    File.write(plan.fetch('profile_file'), JSON.pretty_generate(profile) + "\n")
    File.write(plan.fetch('stage_stamp'), "#{sha256(plan.fetch('manifest_file'))}\n")
    puts "Staged candidate prefix: #{prefix}"
    puts "Candidate manifest: #{plan.fetch('manifest_file')}"
  end

  def run_seal(plan_path)
    plan = JSON.parse(File.read(plan_path))
    manifest_path = plan.fetch('manifest_file')
    raise Error, 'candidate must be staged before sealing' unless File.file?(manifest_path)
    receipt = JSON.parse(File.read(plan.fetch('acceptance_file')))
    manifest = JSON.parse(File.read(manifest_path))
    unless tree_sha256(plan.fetch('install_prefix')) == manifest.fetch('prefix_tree_sha256')
      raise Error, 'candidate prefix changed after its staged manifest was written'
    end
    expected = {
      'status' => 'pass',
      'source_commit' => plan.fetch('source_commit'),
      'install_prefix' => plan.fetch('install_prefix'),
      'candidate_manifest_sha256' => sha256(manifest_path)
    }
    expected.each do |key, value|
      raise Error, "VM acceptance receipt has mismatched #{key}" unless receipt[key] == value
    end
    sealed = {
      'status' => 'sealed-after-external-vm-acceptance',
      'source_commit' => plan.fetch('source_commit'),
      'install_prefix' => plan.fetch('install_prefix'),
      'candidate_manifest_sha256' => sha256(manifest_path),
      'acceptance_receipt_sha256' => sha256(plan.fetch('acceptance_file')),
      'receipt' => receipt
    }
    File.write(plan.fetch('sealed_file'), JSON.pretty_generate(sealed) + "\n")
    puts "Sealed candidate qualification receipt: #{plan.fetch('sealed_file')}"
  end

  def main(argv)
    if argv.first == '--internal'
      action = argv.fetch(1)
      plan = argv.fetch(2)
      return run_stage(plan) if action == 'stage'
      return run_seal(plan) if action == 'seal'
      raise Error, "unknown internal action: #{action}"
    end
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: rebuild-clang-cpu-classifier.rb --source-root PATH --baseline-build PATH --baseline-prefix PATH --tool-root PATH --build-root PATH --install-prefix PATH [--regenerate-small-linker-script]'
      {
        '--source-root PATH' => :source_root,
        '--baseline-build PATH' => :baseline_build,
        '--baseline-prefix PATH' => :baseline_prefix,
        '--tool-root PATH' => :tool_root,
        '--build-root PATH' => :build_root,
        '--install-prefix PATH' => :install_prefix
      }.each { |switch, key| opts.on(switch) { |value| options[key] = value } }
      opts.on('--regenerate-small-linker-script',
              'Regenerate only dos-clang-small.ld from this source tree') do
        options[:regenerate_small_linker_script] = true
      end
      opts.on('-h', '--help', 'Show this help') { puts opts; exit 0 }
    end
    parser.parse!(argv)
    missing = %i[source_root baseline_build baseline_prefix tool_root build_root install_prefix] - options.keys
    raise Error, "missing required options: #{missing.join(', ')}" unless missing.empty?
    run_cli(options)
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    IA16RuntimeRebuilder.main(ARGV)
  rescue IA16RuntimeRebuilder::Error, JSON::ParserError, KeyError, OptionParser::ParseError => e
    warn "error: #{e.message}"
    exit 1
  end
end
