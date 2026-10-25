#!/usr/bin/env ruby
require 'digest'
require 'fileutils'
require 'json'
require 'optparse'

options = { emulator: ENV.fetch('DOSBOX_X', 'dosbox-x'), xvfb_run: 'xvfb-run' }
OptionParser.new do |parser|
  parser.banner = 'Usage: run-guest.rb --out DIR [--emulator PATH] [--xvfb-run PATH]'
  parser.on('--out DIR', 'Build directory produced by run.rb') { |v| options[:out] = v }
  parser.on('--emulator PATH', 'DOSBox-X executable (or DOSBOX_X environment variable)') { |v| options[:emulator] = v }
  parser.on('--xvfb-run PATH', 'Xvfb launcher used with DOSBox-X --silent') { |v| options[:xvfb_run] = v }
end.parse!
abort 'missing required option: --out DIR' unless options[:out]

root = File.realpath(options.fetch(:out))
drive = File.join(root, 'drive')
resolve_executable = lambda do |command|
  candidates = if command.include?(File::SEPARATOR)
                 [command]
               else
                 ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).map { |dir| File.join(dir, command) }
               end
  path = candidates.find { |candidate| File.file?(candidate) && File.executable?(candidate) }
  abort "executable not found: #{command}" unless path
  File.realpath(path)
end
emulator = resolve_executable.call(options.fetch(:emulator))
xvfb_run = resolve_executable.call(options.fetch(:xvfb_run))
config = File.join(root, 'dosbox.conf')
build_results = File.join(root, 'build-results.json')
abort "missing DOSBox config: #{config}" unless File.file?(config)
abort "missing build receipts: #{build_results}" unless File.file?(build_results)

%w[START.TXT DONE.TXT FAIL.TXT NATIVE.OUT FULL.OUT THIN.OUT FULL23.OUT
   NATIVE.STS FULL.STS THIN.STS FULL23.STS LTO.TMP].each do |name|
  FileUtils.rm_f(File.join(drive, name))
end
%w[config data cache].each { |name| FileUtils.mkdir_p(File.join(root, name)) }

argv = [xvfb_run, '-a', '-s', '-screen 0 1024x768x24', emulator,
        '-conf', config, '-fastlaunch', '-nogui', '-silent']
host_log_path = File.join(root, 'host.log')
host_log = File.open(host_log_path, 'w')
env = {
  'SDL_AUDIODRIVER' => 'dummy',
  'XDG_CONFIG_HOME' => File.join(root, 'config'),
  'XDG_DATA_HOME' => File.join(root, 'data'),
  'XDG_CACHE_HOME' => File.join(root, 'cache')
}
pid = Process.spawn(env, *argv, out: host_log, err: [:child, :out], chdir: root, pgroup: true)
host_log.close
File.write(File.join(root, 'dosbox.pgid'), "#{pid}\n")

read_guest = lambda do |name|
  path = File.join(drive, name)
  File.file?(path) ? File.read(path).strip : nil
end
guest_status = lambda do
  outputs = %w[NATIVE.OUT FULL.OUT THIN.OUT FULL23.OUT].to_h do |name|
    [name, read_guest.call(name)]
  end
  exits = %w[NATIVE.STS FULL.STS THIN.STS FULL23.STS].to_h do |name|
    [name, read_guest.call(name)]
  end
  expected_markers = ['IA16 MZ CTOR PASS', 'IA16 MZ LTO PASS', 'IA16 MZ DTOR PASS']
  complete = read_guest.call('START.TXT') == 'START' &&
             read_guest.call('DONE.TXT') == 'DONE' &&
             exits.values_at('NATIVE.STS', 'FULL.STS', 'THIN.STS').all? { |v| v == 'EXIT=0' } &&
             exits['FULL23.STS'] == 'EXIT=23' &&
             outputs.values.all? { |output| output && expected_markers.all? { |marker| output.include?(marker) } } &&
             outputs['FULL23.OUT'].include?('IA16 MZ LTO EXIT 23') &&
             !File.exist?(File.join(drive, 'FAIL.TXT')) &&
             !File.exist?(File.join(drive, 'LTO.TMP'))
  {
    start_marker: read_guest.call('START.TXT'),
    completion_marker: read_guest.call('DONE.TXT'),
    failure_marker: read_guest.call('FAIL.TXT'),
    stdout: outputs,
    dos_exit_receipts: exits,
    file_io_temp_removed: !File.exist?(File.join(drive, 'LTO.TMP')),
    complete: complete
  }
end

puts "DOSBox-X PID/PGID #{pid}; waiting for DOS guest receipts"
status = nil
stopped_after_receipt = false
loop do
  waited, status = Process.wait2(pid, Process::WNOHANG)
  break if waited

  state = guest_status.call
  if state[:complete] || state[:failure_marker]
    stopped_after_receipt = true
    begin
      Process.kill('INT', -pid)
    rescue Errno::ESRCH
    end
    _, status = Process.wait2(pid)
    break
  end

  sleep 0.25
end

final_state = guest_status.call
build = JSON.parse(File.read(build_results))
result = final_state.merge(
  runner_exit_status: status.exitstatus,
  runner_signal: status.termsig,
  stopped_after_guest_receipt: stopped_after_receipt,
  execution_mode: 'DOSBox-X --silent; dummy video and dummy audio; headless guest only',
  host_log: host_log_path,
  stdout_sha256: %w[NATIVE.OUT FULL.OUT THIN.OUT FULL23.OUT].to_h do |name|
    path = File.join(drive, name)
    [name, File.file?(path) ? Digest::SHA256.file(path).hexdigest : nil]
  end,
  emulator_sha256: Digest::SHA256.file(emulator).hexdigest,
  config_sha256: Digest::SHA256.file(config).hexdigest,
  cpu: '8086',
  compiler: build.fetch('compiler'),
  compiler_sha256: build.fetch('compiler_sha256'),
  linker: build.fetch('linker'),
  linker_sha256: build.fetch('linker_sha256'),
  runtime: build.fetch('runtime'),
  runtime_sha256: build.fetch('runtime_sha256'),
  executable_sha256: build.fetch('executable_sha256'),
  status: (final_state[:complete] ? 'pass' : 'fail')
)
File.write(File.join(root, 'launch.json'), JSON.pretty_generate({
  cpu: result[:cpu],
  argv: argv,
  cwd: root,
  xvfb_wrapper: '1024x768x24; SDL video output remains dummy under DOSBox-X --silent',
  headless: true,
  video: 'dummy (DOSBox-X --silent; no guest UI/display claim)',
  audio: 'dummy',
  process_group: pid,
  emulator_sha256: result[:emulator_sha256],
  config_sha256: result[:config_sha256],
  compiler: result[:compiler],
  compiler_sha256: result[:compiler_sha256],
  linker: result[:linker],
  linker_sha256: result[:linker_sha256],
  runtime: result[:runtime],
  runtime_sha256: result[:runtime_sha256],
  executable_sha256: result[:executable_sha256],
  semantic_completion: %w[START.TXT DONE.TXT NATIVE.STS FULL.STS THIN.STS FULL23.STS]
}) + "\n")
File.write(File.join(root, 'guest-results.json'), JSON.pretty_generate(result) + "\n")
puts JSON.pretty_generate(result)
abort "DOSBox guest acceptance failed; inspect #{root}/guest-results.json" unless result[:status] == 'pass'
