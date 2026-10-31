#!/usr/bin/env ruby
# Build the IA-16 DOS Clang runtime profiles without Make.

require 'fileutils'
require 'digest'
require 'json'
require 'open3'
require 'optparse'
require 'pathname'
require 'shellwords'
require_relative 'generate-dos-clang-mz'

module IA16ClangSysroot
  TARGET = 'ia16-pc-msdos'.freeze
  MODELS = {
    tiny:    { letter: 't', code_pointers: :near, data_pointers: :near, startup: 'dos-t-c0.o',
               bsp: 'libdos-t.a', linker_script: 'dos-clang-tiny.ld', template: 'dos-mt.ld.in' },
    small:   { letter: 's', code_pointers: :near, data_pointers: :near, startup: 'dos-s-c0.o',
               bsp: 'libdos-s.a', linker_script: 'dos-clang-small.ld', template: 'dos-clang-mz.ld.in' },
    medium:  { letter: 'm', code_pointers: :far, data_pointers: :near, startup: 'dos-m-c0.o',
               bsp: 'libdos-m.a', linker_script: 'dos-clang-medium.ld', template: 'dos-clang-mz.ld.in' },
    compact: { letter: 'c', code_pointers: :near, data_pointers: :far, startup: 'dos-c-c0.o',
               bsp: 'libdos-c.a', linker_script: 'dos-clang-compact.ld', template: 'dos-clang-mz.ld.in' },
    large:   { letter: 'l', code_pointers: :far, data_pointers: :far, startup: 'dos-l-c0.o',
               bsp: 'libdos-l.a', linker_script: 'dos-clang-large.ld', template: 'dos-clang-mz.ld.in' }
  }.transform_values(&:freeze).freeze

  DOS_COMMON_OBJECTS = %w[
    dos-emutls dos-far-data-syscalls dos-access dos-chdir dos-chmod dos-closer dos-cvt-file-time dos-dbcs
    dos-dbcs-strcspn dos-dup dos-dup2 dos-environ dos-argv dos-kill dos-fstatr dos-getcwd
    dos-getcwd-impl dos-gettimeofdayr dos-heaplen dos-isattyr dos-lseekr dos-mkdir
    dos-mkdirr dos-near-data-segment dos-openr dos-psp dos-readr dos-realpath
    dos-renamer dos-rmdir dos-sbrkr dos-statr dos-timesr dos-uname dos-uname-impl
    dos-unlinkr dos-usleep dos-writer dos-getpid dos-dbcs-weaks
  ].freeze
  DOS_MODEL_OBJECTS = {
    tiny: %w[dos-mtabort dos-mti0 dos-mti1 dos-mtv1],
    small: %w[dos-msmmabort dos-mxi0 dos-mxi1 dos-mxv1],
    medium: %w[dos-msmmabort dos-mxv1],
    compact: %w[dos-msmmabort dos-mxv1],
    large: %w[dos-msmmabort dos-mxv1]
  }.transform_values(&:freeze).freeze

  def self.builtins_relative_path(model)
    model = model.to_sym
    raise ArgumentError, "unsupported IA-16 memory model: #{model}" unless MODELS.key?(model)
    suffix = 'libclang_rt.builtins-ia16.a'
    model == :small ? "lib/baremetal/#{suffix}" : "lib/baremetal/#{model}/#{suffix}"
  end

  # Read the simple recursive variables from a configured Automake Makefile.
  # This consumes the configure result only; it never evaluates or runs Make.
  class MakeVariables
    ASSIGNMENT = /\A([A-Za-z_][A-Za-z0-9_]*)\s*(\+=|=)\s*(.*)\z/.freeze
    REFERENCE = /\$\(([A-Za-z_][A-Za-z0-9_]*)\)/.freeze

    def initialize(text)
      @variables = {}
      text.gsub(/\\\r?\n/, ' ').each_line do |line|
        line = line.sub(/\s+#.*\z/, '').strip
        next if line.empty? || line.start_with?('#')
        match = ASSIGNMENT.match(line)
        next unless match
        name, operator, value = match.captures
        @variables[name] = [@variables[name], value].compact.join(' ') if operator == '+='
        @variables[name] = value if operator == '='
      end
    end

    def words(name)
      expand(@variables.fetch(name, '')).split
    end

    def scalar(name)
      expand(@variables.fetch(name, '')).strip
    end

    private

    def expand(value, seen = [])
      value.gsub(REFERENCE) do
        name = Regexp.last_match(1)
        next '' if seen.include?(name)
        expand(@variables.fetch(name, ''), seen + [name])
      end
    end
  end

  class Builder
    def initialize(source_root:, tool_root:, build_root:, install_prefix:, builtins_root:, jobs: 4,
                   models: MODELS.keys)
      @source = Pathname(source_root).realpath
      @tools = Pathname(tool_root).realpath
      @build = Pathname(build_root).expand_path
      @install = Pathname(install_prefix).expand_path
      @builtins = Pathname(builtins_root).realpath
      @jobs = Integer(jobs)
      @models = models.map(&:to_sym)
      raise ArgumentError, 'jobs must be positive' unless @jobs.positive?
      unknown = @models - MODELS.keys
      raise ArgumentError, "unsupported models: #{unknown.join(', ')}" unless unknown.empty?
      raise ArgumentError, 'select at least one memory model' if @models.empty?
      [@source, @tools, @build, @install, @builtins].each do |path|
        raise ArgumentError, "path contains unsupported shell or Make characters: #{path}" if
          path.to_s.match?(/[\s$#`\\"';&|<>(){}\[\]*?!]/)
      end
      @clang = @tools / 'bin/clang'
      @ld = @tools / 'bin/ld.lld'
      [@source / 'newlib/configure', @clang, @ld].each do |path|
        raise ArgumentError, "required input missing: #{path}" unless path.file?
      end
      @builtins_root = @builtins
      @manifest = { 'status' => 'running', 'target' => TARGET, 'models' => {}, 'commands' => [] }
    end

    def run
      @build.mkpath
      @install.mkpath
      @models.each { |model| build_model(model) }
      @manifest['status'] = 'pass'
      save_manifest
      puts JSON.pretty_generate('status' => 'pass', 'profile' => (@install / 'profile.sh').to_s,
                                'manifest' => (@build / 'build-profile.json').to_s)
    rescue StandardError => error
      @manifest['status'] = 'fail'
      @manifest['error'] = error.message
      save_manifest
      raise
    end

    private

    def build_model(model)
      model_root = @build / model.to_s
      newlib_build = model_root / 'newlib'
      sysroot = @install / TARGET / model.to_s
      newlib_build.mkpath
      (newlib_build / 'targ-include').mkpath
      resource = Pathname(capture([@clang, '-print-resource-dir']).strip).realpath
      @resource_dir = resource
      overlay = newlib_build / 'targ-include'
      generic = @source / 'newlib/libc/include'
      cc = [@clang, "--target=#{TARGET}", '-march=8086', "-mmemory-model=#{model}", '-nostdinc',
            "-I#{overlay}", "-I#{generic}", '-isystem', overlay.to_s,
            '-isystem', generic.to_s, '-isystem', (resource / 'include').to_s]
      env = clean_environment.merge(
        'CC' => cc.map(&:to_s).join(' '),
        'CFLAGS' => '-std=gnu17 -Oz -femulated-tls -ffreestanding -fno-builtin -nostdinc',
        'AR' => find_tool('ar'), 'RANLIB' => find_tool('ranlib'),
        'NM' => find_tool('nm'), 'OBJCOPY' => find_tool('objcopy')
      )
      builtins = @builtins_root / IA16ClangSysroot.builtins_relative_path(model)
      raise "missing #{model} compiler-rt archive: #{builtins}" unless builtins.file?
      @manifest['models'][model.to_s] = {
        'code_pointers' => MODELS.fetch(model).fetch(:code_pointers).to_s,
        'data_pointers' => MODELS.fetch(model).fetch(:data_pointers).to_s,
        'sysroot' => sysroot.to_s,
        'builtins' => builtins.to_s,
        'commands' => []
      }
      save_manifest

      configure = [@source / 'newlib/configure', "--host=#{TARGET}", "--target=#{TARGET}",
                   "--prefix=#{sysroot}", '--disable-multilib']
      run_model_command(model, 'configure', configure, cwd: newlib_build, env: env)
      stage_headers(model, newlib_build, sysroot)
      variables = MakeVariables.new((newlib_build / 'Makefile').read)
      libc_sources = source_files(variables.words('libc_a_SOURCES'), 'newlib')
      # Generic string C providers honor every data/code pointer ABI. The
      # historical IA-16 assembly strings have near-data signatures; including
      # both gives duplicate strong symbols and archive-order-dependent ABI.
      libc_sources.reject! do |source|
        relative = source.relative_path_from(@source / 'newlib').to_s
        (relative.start_with?('libc/machine/ia16/') && source.extname == '.S' &&
          source.basename.to_s != 'setjmp.S') || relative == 'libc/stdlib/environ.c'
      end
      libm_sources = source_files(variables.words('libm_a_SOURCES'), 'newlib')
      raise "#{model}: configured Newlib source list is empty" if libc_sources.empty? || libm_sources.empty?
      @manifest['models'][model.to_s]['newlib_sources'] = {
        'libc' => libc_sources.length, 'libm' => libm_sources.length
      }

      graph = model_root / 'build.ninja'
      libc_objects, libm_objects = write_newlib_graph(model, model_root, libc_sources,
                                                      libm_sources, resource, overlay)
      dos_objects, startup = write_libgloss_graph(model, model_root, resource, overlay)
      write_graph(graph, model_root, libc_objects, libm_objects, dos_objects, startup)
      run_model_command(model, 'ninja', ['ninja', '-C', model_root, "-j#{@jobs}"],
                        cwd: model_root)
      install_model(model, model_root, sysroot, builtins, resource)
    end

    def capture(argv)
      output, error, status = Open3.capture3(*argv.map(&:to_s))
      raise "#{argv.first} failed: #{error}" unless status.success?
      output
    end

    def clean_environment
      env = ENV.to_h
      %w[CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH COMPILER_PATH
         LIBRARY_PATH GCC_EXEC_PREFIX].each { |name| env.delete(name) }
      env
    end

    def find_tool(name)
      path = ENV.fetch('PATH').split(File::PATH_SEPARATOR)
                 .map { |directory| Pathname(directory) / name }.find(&:executable?)
      raise "required host tool missing: #{name}" unless path
      path.to_s
    end

    def run_model_command(model, name, argv, cwd:, env: {})
      entry = @manifest['models'].fetch(model.to_s)
      command = argv.map(&:to_s)
      log = @build / model.to_s / "#{name}.log"
      log.parent.mkpath
      item = { 'name' => name, 'command' => command, 'cwd' => cwd.to_s, 'log' => log.to_s }
      entry['commands'] << item
      @manifest['commands'] << item
      save_manifest
      File.open(log, 'w') do |stream|
        stream.puts("$ #{Shellwords.join(command)}")
        stream.flush
        stdout, stderr, status = Open3.capture3(env, *command, chdir: cwd.to_s,
                                                  out: stream, err: [:child, :out])
        stream.write(stdout)
        stream.write(stderr)
        item['exit'] = status.exitstatus
        save_manifest
        raise "#{model} #{name} failed with status #{status.exitstatus}; see #{log}" unless status.success?
      end
    end

    def digest(path)
      require 'digest'
      Digest::SHA256.file(path).hexdigest
    end

    def save_manifest
      File.write(@build / 'build-profile.json', JSON.pretty_generate(@manifest) + "\n")
    end

    def source_files(paths, area)
      paths.filter_map do |relative|
        next unless relative.match?(/\.(?:c|S|s)\z/)
        path = @source / area / relative
        raise "configured source is missing: #{path}" unless path.file?
        path
      end
    end

    def copy_headers(source, destination)
      return unless source.directory?
      source.glob('**/*.h').each do |header|
        target = destination / header.relative_path_from(source)
        target.dirname.mkpath
        FileUtils.cp(header, target)
      end
    end

    def stage_headers(model, newlib_build, sysroot)
      vars = MakeVariables.new((newlib_build / 'Makefile').read)
      target_include = newlib_build / 'targ-include'
      target_include.mkpath
      machine = @source / 'newlib/libc/machine' / vars.scalar('machine_dir')
      system = @source / 'newlib/libc/sys' / vars.scalar('sys_dir')
      copy_headers(machine / 'machine', target_include / 'machine')
      copy_headers(machine / 'sys', target_include / 'sys')
      copy_headers(machine / 'include', target_include)
      copy_headers(system / 'include', target_include)
      %w[sys bits machine].each { |directory| copy_headers(system / directory, target_include / directory) }
      copy_headers(system / 'machine' / vars.scalar('machine_dir'), target_include / 'machine')
      copy_headers(system / 'machine' / vars.scalar('machine_dir') / 'include', target_include / 'machine')
      %w[newlib.h _newlib_version.h].each do |name|
        generated = newlib_build / name
        raise "#{model}: configure did not produce #{generated}" unless generated.file?
        FileUtils.cp(generated, target_include / name)
      end
      include_dir = sysroot / 'include'
      copy_headers(@source / 'newlib/libc/include', include_dir / 'newlib')
      copy_headers(target_include, include_dir)
    end

    def ninja_quote(value)
      value.to_s.gsub('$', '$$').gsub(' ', '$ ').gsub(':', '$:')
    end

    def command_fragment(argv)
      Shellwords.join(argv.map(&:to_s))
    end

    def write_newlib_graph(model, model_root, libc_sources, libm_sources, resource, overlay)
      object_root = model_root / 'objects'
      include_flags = ['-I', overlay, '-I', @source / 'newlib/libc/include',
                       '-I', @source / 'newlib/libc/machine/ia16',
                       '-I', @source / 'newlib/libm/common', '-idirafter', @source / 'include',
                       '-isystem', resource / 'include']
      base_flags = ['--target=' + TARGET, '-march=8086', "-mmemory-model=#{model}",
                    '-std=gnu17', '-Oz', '-femulated-tls', '-ffreestanding', '-fno-builtin',
                    '-nostdinc', '-D_LIBC', '-DREENTRANT_SYSCALLS_PROVIDED', '-DHAVE_RENAME',
                    '-DPREFER_SIZE_OVER_SPEED', '-D_COMPILING_NEWLIB', '-D_HAVE_INIT_FINI'] + include_flags
      libc_objects = newlib_objects(libc_sources, object_root / 'libc', 'libc', base_flags)
      libm_objects = newlib_objects(libm_sources, object_root / 'libm', 'libm',
                                    base_flags + ['-fbuiltin', '-fno-math-errno'])
      [libc_objects, libm_objects]
    end

    def newlib_objects(sources, object_root, library, flags)
      sources.map do |source|
        relative = source.relative_path_from(@source / 'newlib')
        stem = relative.to_s.sub(/\.(?:c|S|s)\z/, '').gsub(/[^A-Za-z0-9_]+/, '_')
        object = object_root / "#{library}_a-#{stem}.o"
        object.dirname.mkpath
        (@object_commands ||= {})[object] = [source, flags]
        object
      end
    end

    def write_libgloss_graph(model, model_root, resource, overlay)
      libgloss = @source / 'libgloss/ia16'
      model_root_l = model_root / 'libgloss'
      model_root_l.mkpath
      ccflags = ['--target=' + TARGET, '-march=8086', "-mmemory-model=#{model}", '-Os',
                 '-femulated-tls', '-ffreestanding', '-fno-builtin', '-nostdinc',
                 '-I', libgloss, '-I', overlay, '-I', @source / 'newlib/libc/include',
                 '-isystem', resource / 'include', "-D#{model.to_s.upcase}"]
      objects = (DOS_COMMON_OBJECTS + DOS_MODEL_OBJECTS.fetch(model)).uniq.map do |name|
        source = find_libgloss_source(libgloss, name)
        object = model_root_l / 'objects' / "#{name}.o"
        object.dirname.mkpath
        (@object_commands ||= {})[object] = [source, ccflags]
        object
      end
      startup_source = libgloss / 'dos-models-crt0.S'
      startup = model_root_l / MODELS.fetch(model).fetch(:startup)
      (@object_commands ||= {})[startup] = [startup_source, ccflags]
      [objects, startup]
    end

    def find_libgloss_source(directory, name)
      %w[.S .s .c].each do |suffix|
        path = directory / "#{name}#{suffix}"
        return path if path.file?
      end
      raise "no source file found for libgloss object #{name}"
    end

    def write_graph(path, model_root, libc_objects, libm_objects, dos_objects, startup)
      libgloss_root = model_root / 'libgloss'
      config = MODELS.fetch(model_root.basename.to_s.to_sym)
      newlib_build = model_root / 'newlib'
      libc_archive = newlib_build / 'libc.a'
      libm_archive = newlib_build / 'libm.a'
      dos_archive = libgloss_root / config.fetch(:bsp)
      lines = [
        'ninja_required_version = 1.3', "cc = #{ninja_quote(@clang)}",
        "ar = #{ninja_quote(find_tool('ar'))}", "ranlib = #{ninja_quote(find_tool('ranlib'))}",
        'rule cc', '  command = $cc $flags -MMD -MF $out.d -c $in -o $out',
        '  depfile = $out.d', '  deps = gcc', '  description = CC $out',
        'rule archive', '  command = rm -f $out && $ar rcs $out $in && $ranlib $out', '  description = AR $out'
      ]
      (libc_objects + libm_objects + dos_objects + [startup]).each do |object|
        source, flags = @object_commands.fetch(object)
        lines << "build #{ninja_quote(object)}: cc #{ninja_quote(source)} | #{ninja_quote(@clang)}"
        lines << "  flags = #{command_fragment(flags)}"
      end
      lines << "build #{ninja_quote(libm_archive)}: archive #{libm_objects.map { |o| ninja_quote(o) }.join(' ')}"
      lines << "build #{ninja_quote(libc_archive)}: archive #{libc_objects.map { |o| ninja_quote(o) }.join(' ')}"
      lines << "build #{ninja_quote(dos_archive)}: archive #{dos_objects.map { |o| ninja_quote(o) }.join(' ')}"
      lines << "build all: phony #{ninja_quote(libc_archive)} #{ninja_quote(libm_archive)} #{ninja_quote(dos_archive)} #{ninja_quote(startup)}"
      lines << 'default all'
      File.write(path, lines.join("\n") + "\n")
    end

    def install_model(model, model_root, sysroot, builtins, resource)
      lib_dir = sysroot / 'lib'
      lib_dir.mkpath
      %w[libc.a libm.a].each { |archive| FileUtils.cp(model_root / 'newlib' / archive, lib_dir / archive) }
      config = MODELS.fetch(model)
      FileUtils.cp(model_root / 'libgloss' / config.fetch(:bsp), lib_dir / config.fetch(:bsp))
      FileUtils.cp(model_root / 'libgloss' / config.fetch(:startup), lib_dir / config.fetch(:startup))
      FileUtils.cp(builtins, lib_dir / 'libclang_rt.builtins-ia16.a')
      if model == :tiny
        args = ['sh', @source / 'libgloss/ia16' / config.fetch(:template),
                '-nostdlib', '-mclang-runtime']
        script, stderr, status = Open3.capture3(*args.map(&:to_s))
        raise "#{model} linker script generation failed: #{stderr}" unless status.success?
      else
        script = IA16ClangSysroot.dos_clang_mz_script(
          File.read(@source / 'libgloss/ia16' / config.fetch(:template)))
      end
      File.write(lib_dir / config.fetch(:linker_script), script)
      write_profiles
      manifest = @manifest['models'].fetch(model.to_s)
      manifest['compiler_sha256'] = digest(@clang)
      manifest['linker_sha256'] = digest(@ld)
      manifest['builtins_sha256'] = digest(builtins)
      manifest['installed_archives'] = %w[libc.a libm.a].to_h do |name|
        [name, digest(lib_dir / name)]
      end
      manifest['headers'] = (sysroot / 'include').glob('**/*.h').length
      manifest['resource_dir'] = resource.to_s
      save_manifest
    end

    def write_profiles
      profiles = ['# Generated IA-16 DOS Clang profiles; source this file.']
      @manifest['models'].each_key do |name|
        model = name.to_sym
        config = MODELS.fetch(model)
        sysroot = @install / TARGET / name
        compile = [@clang, "--target=#{TARGET}", "--sysroot=#{sysroot}", '-march=8086',
                   "-mmemory-model=#{model}", '-std=gnu23', '-Os', '-femulated-tls',
                   '-ffreestanding', '-fno-builtin', '-ffunction-sections', '-fdata-sections',
                   '-nostdinc', '-isystem', sysroot / 'include',
                   '-isystem', sysroot / 'include/newlib', '-isystem', @resource_dir / 'include']
        profiles << "ia16_clang_#{model}() {"
        profiles << "  #{Shellwords.join(compile.map(&:to_s))} \"$@\""
        profiles << '}'
        linker = [@clang, "--target=#{TARGET}", "--sysroot=#{sysroot}", '-march=8086',
                  "-mmemory-model=#{model}", "-resource-dir=#{@builtins_root}",
                  '-fuse-ld=lld', '-Wl,-m,elf_ia16',
                  '-Wl,-T,' + (sysroot / 'lib' / config.fetch(:linker_script)).to_s,
                  '-L', sysroot / 'lib', sysroot / 'lib' / config.fetch(:startup)]
        linker << (model == :tiny ? '-Wl,--oformat=binary' : '-Wl,--oformat=mz')
        library = config.fetch(:bsp).sub(/\Alib/, '').sub(/\.a\z/, '')
        tail = ['-Wl,--start-group', '-lc', "-l#{library}", '-lm', '-Wl,--end-group']
        profiles << "ia16_link_#{model}() {"
        profiles << "  #{Shellwords.join(linker.map(&:to_s))} \"$@\" #{Shellwords.join(tail.map(&:to_s))}"
        profiles << '}'
        direct = [@ld, '-m', 'elf_ia16']
        direct << '--oformat=mz' unless model == :tiny
        direct += ['-T',
                  sysroot / 'lib' / config.fetch(:linker_script), '-L', sysroot / 'lib',
                  sysroot / 'lib' / config.fetch(:startup)]
        direct_tail = ['--start-group', '-lc', "-l#{library}", '-lm']
        query = [@clang, "--target=#{TARGET}", "-mmemory-model=#{model}",
                 "-resource-dir=#{@builtins_root}", '--print-libgcc-file-name']
        profiles << "ia16_direct_link_#{model}() {"
        profiles << "  ia16_builtins=$(#{Shellwords.join(query.map(&:to_s))}) || return"
        profiles << '  test -f "$ia16_builtins" || return 1'
        profiles << "  #{Shellwords.join(direct.map(&:to_s))} \"$@\" #{Shellwords.join(direct_tail.map(&:to_s))} \"$ia16_builtins\" --end-group"
        profiles << '}'
      end
      File.write(@install / 'profile.sh', profiles.join("\n") + "\n")
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { jobs: 4, models: IA16ClangSysroot::MODELS.keys }
  OptionParser.new do |parser|
    parser.banner = 'Usage: build-clang-sysroot.rb --source-root DIR --tool-root DIR --build-root DIR --install-prefix DIR --builtins-root DIR'
    parser.on('--source-root DIR') { |value| options[:source_root] = value }
    parser.on('--tool-root DIR') { |value| options[:tool_root] = value }
    parser.on('--build-root DIR') { |value| options[:build_root] = value }
    parser.on('--install-prefix DIR') { |value| options[:install_prefix] = value }
    parser.on('--builtins-root DIR') { |value| options[:builtins_root] = value }
    parser.on('--jobs N', Integer) { |value| options[:jobs] = value }
    parser.on('--models LIST', 'comma-separated model list') do |value|
      options[:models] = value.split(',').map(&:strip)
    end
  end.parse!
  missing = %i[source_root tool_root build_root install_prefix builtins_root] - options.keys
  abort "missing required options: #{missing.join(', ')}" unless missing.empty?
  IA16ClangSysroot::Builder.new(**options).run
end
