#!/usr/bin/env ruby
# Compile, link, and execute DOS guests through each Clang/newlib memory model.

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'pathname'
require 'shellwords'

MODELS = %w[tiny small medium compact large].freeze
ROOT = Pathname(__dir__).realpath

options = { models: MODELS, emulator: 'dosbox' }
OptionParser.new do |parser|
  parser.banner = 'Usage: run.rb --profile PATH --out DIR [--emulator PATH]'
  parser.on('--profile PATH', 'Generated profile.sh from build-clang-sysroot.rb') { |value| options[:profile] = value }
  parser.on('--out DIR', 'Fresh acceptance output directory') { |value| options[:out] = value }
  parser.on('--models LIST', 'Comma-separated memory model list') { |value| options[:models] = value.split(',') }
  parser.on('--emulator PATH') { |value| options[:emulator] = value }
end.parse!
abort 'missing required option: --profile PATH' unless options[:profile]
abort 'missing required option: --out DIR' unless options[:out]
options[:models] = options[:models].map(&:strip)
abort "unsupported model in #{options[:models].inspect}" unless (options[:models] - MODELS).empty?
abort 'select at least one model' if options[:models].empty?

profile = Pathname(options[:profile]).realpath
out = Pathname(options[:out]).expand_path
abort "output directory already contains files: #{out}" if out.exist? && !out.children.empty?
abort 'acceptance paths may not contain spaces' if [profile, out].any? { |path| path.to_s.match?(/\s/) }

resolve_executable = lambda do |name|
  candidates = name.include?(File::SEPARATOR) ? [name] :
    ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).map { |directory| File.join(directory, name) }
  candidate = candidates.find { |path| File.file?(path) && File.executable?(path) }
  abort "executable not found: #{name}" unless candidate
  Pathname(candidate).realpath
end

emulator = resolve_executable.call(options[:emulator])
out.mkpath
fixture = <<~'C'
  #include <unistd.h>

  static volatile unsigned int callback_state;
  static volatile unsigned int *volatile state_pointer = &callback_state;

  static int add_three(int value) { return value + 3; }
  static int (*volatile callback)(int) = add_three;

  __attribute__((constructor(101))) static void first_constructor(void) {
    callback_state = 1;
  }

  __attribute__((constructor(202))) static void second_constructor(void) {
    callback_state = callback_state * 2 + 1;
  }

  int main(void) {
    if (*state_pointer == 3 && callback(39) == 42)
      *state_pointer = 276;
    else
      *state_pointer = 0;
    return 0;
  }

  __attribute__((destructor(101))) static void write_result(void) {
    static const char pass[] = "PASS 276 42\n";
    static const char fail[] = "FAIL\n";
    if (*state_pointer == 276 && callback(39) == 42)
      (void)write(1, pass, sizeof(pass) - 1);
    else
      (void)write(1, fail, sizeof(fail) - 1);
  }
C
fixture_sha256 = Digest::SHA256.hexdigest(fixture)
results = {}

options[:models].each do |model|
  lane = out / model
  lane.mkpath
  source = lane / 'memory_model.c'
  object = lane / 'memory_model.o'
  File.write(source, fixture)
  driver_image = lane / (model == 'tiny' ? 'DRIVER.COM' : 'DRIVER.EXE')
  direct_image = lane / (model == 'tiny' ? 'DIRECT.COM' : 'DIRECT.EXE')
  shell_prefix = ". #{Shellwords.escape(profile.to_s)} && "
  compile = "ia16_clang_#{model} -c #{Shellwords.escape(source.to_s)} -o #{Shellwords.escape(object.to_s)}"
  driver_link = "ia16_link_#{model} #{Shellwords.escape(object.to_s)} -o #{Shellwords.escape(driver_image.to_s)}"
  direct_link = "ia16_direct_link_#{model} #{Shellwords.escape(object.to_s)} -o #{Shellwords.escape(direct_image.to_s)}"
  compile_out, compile_error, compile_status = Open3.capture3('bash', '-e', '-c',
    "#{shell_prefix}#{compile} && #{driver_link} && #{direct_link}")
  unless compile_status.success?
    abort "#{model}: compile/link failed\n#{compile_out}\n#{compile_error}"
  end

  guest_drive = lane / 'drive'
  guest_drive.mkpath
  FileUtils.cp(driver_image, guest_drive / driver_image.basename)
  FileUtils.cp(direct_image, guest_drive / direct_image.basename)
  batch = <<~BAT.gsub("\n", "\r\n")
    @echo off
    #{driver_image.basename} > DRIVER.TXT
    if errorlevel 1 goto fail
    #{direct_image.basename} > DIRECT.TXT
    if errorlevel 1 goto fail
    echo DONE> DONE.TXT
    goto end
    :fail
    echo FAIL> FAIL.TXT
    :end
  BAT
  File.binwrite(guest_drive / 'RUN.BAT', batch)
  config = <<~CONF
    [sdl]
    fullscreen=false
    output=texture
    texture_renderer=software
    [mouse]
    mouse_capture=nomouse
    mouse_raw_input=false
    [cpu]
    core=normal
    cputype=386
    cycles=max
    [mixer]
    nosound=true
    [autoexec]
    @echo off
    mount c "#{guest_drive}"
    c:
    RUN.BAT
    exit
  CONF
  File.write(lane / 'dosbox.conf', config)
  guest_env = {
    'SDL_VIDEODRIVER' => 'offscreen',
    'SDL_AUDIODRIVER' => 'dummy',
    'XDG_CONFIG_HOME' => (lane / 'config').to_s,
    'XDG_DATA_HOME' => (lane / 'data').to_s,
    'XDG_CACHE_HOME' => (lane / 'cache').to_s
  }
  %w[config data cache].each { |name| (lane / name).mkpath }
  guest_log = lane / 'dosbox.log'
  guest_argv = [emulator, '--set', 'mouse_capture=nomouse', '--set', 'mouse_raw_input=false',
                '--noprimaryconf', '--nolocalconf', '--conf', lane / 'dosbox.conf', '--exit']
  pid = nil
  guest_status = nil
  stopped_after_receipt = false
  File.open(guest_log, 'w') do |stream|
    pid = Process.spawn(guest_env, *guest_argv.map(&:to_s), chdir: lane.to_s,
      out: stream, err: [:child, :out], pgroup: true)
    loop do
      waited, guest_status = Process.wait2(pid, Process::WNOHANG)
      break if waited
      done = (guest_drive / 'DONE.TXT').file?
      failed = (guest_drive / 'FAIL.TXT').file?
      if done || failed
        stopped_after_receipt = true
        begin
          Process.kill('INT', -pid)
        rescue Errno::ESRCH
          # DOSBox already exited after writing its guest receipt.
        end
        _, guest_status = Process.wait2(pid)
        break
      end
      sleep 0.25
    end
    result_files = %w[DRIVER.TXT DIRECT.TXT].to_h do |name|
      path = guest_drive / name
      [name, path.file? ? path.read.strip : nil]
    end
    complete = (guest_drive / 'DONE.TXT').file? &&
      result_files.values.all? { |value| value == 'PASS 276 42' } && !(guest_drive / 'FAIL.TXT').exist?
    results[model] = {
      'status' => complete ? 'pass' : 'fail', 'image' => model == 'tiny' ? 'COM' : 'MZ',
      'driver_link_sha256' => Digest::SHA256.file(driver_image).hexdigest,
      'direct_link_sha256' => Digest::SHA256.file(direct_image).hexdigest,
      'fixture_sha256' => fixture_sha256, 'guest_receipts' => result_files,
      'guest_done' => (guest_drive / 'DONE.TXT').file?, 'emulated_cpu' => '386',
      'emulator_exit' => guest_status.exitstatus, 'emulator_signal' => guest_status.termsig,
      'stopped_after_guest_receipt' => stopped_after_receipt,
      'emulator_sha256' => Digest::SHA256.file(emulator).hexdigest,
      'guest_log' => guest_log.to_s
    }
    File.write(lane / 'result.json', JSON.pretty_generate(results[model]) + "\n")
    puts "#{model}: #{complete ? 'PASS' : 'FAIL'}; driver=#{result_files['DRIVER.TXT'].inspect}; direct=#{result_files['DIRECT.TXT'].inspect}"
    abort "#{model}: guest acceptance failed; inspect #{guest_log} and #{lane / 'result.json'}" unless complete
  end
end

File.write(out / 'results.json', JSON.pretty_generate({
  'status' => 'pass', 'models' => results, 'profile_sha256' => Digest::SHA256.file(profile).hexdigest,
  'emulator' => emulator.to_s, 'video_driver' => 'offscreen'
}) + "\n")
