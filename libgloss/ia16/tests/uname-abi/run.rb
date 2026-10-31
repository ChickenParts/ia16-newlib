#!/usr/bin/env ruby
require 'digest'
require 'fileutils'
require 'json'
require 'optparse'
require 'pathname'
options = { emulator: '/usr/bin/dosbox' }
OptionParser.new do |parser|
  parser.on('--build-dir DIR') { |value| options[:build] = Pathname(value).realpath }
  parser.on('--out DIR') { |value| options[:out] = Pathname(value).expand_path }
  parser.on('--emulator PATH') { |value| options[:emulator] = value }
end.parse!
abort 'missing --build-dir or --out' unless options[:build] && options[:out]
out = options.fetch(:out)
abort "output already exists: #{out}" if out.exist?
images = JSON.parse((options.fetch(:build) / 'images.json').read)
%w[drive config data cache].each { |name| (out / name).mkpath }
batch = ['@echo off']
images.each_with_index do |entry, i|
  image = Pathname(entry.fetch('path'))
  abort "image changed: #{image}" unless Digest::SHA256.file(image).hexdigest == entry.fetch('sha256')
  FileUtils.cp(image, out / "drive/P#{i}.EXE")
  batch += ["P#{i}.EXE > P#{i}.TXT", "if not errorlevel 1 goto next#{i}",
            "echo FAIL>E#{i}.TXT", ":next#{i}"]
end
batch << 'echo DONE>DONE.TXT'
File.binwrite(out / 'drive/RUN.BAT', batch.join("\r\n") + "\r\n")
File.write(out / 'dosbox.conf', <<~CONF)
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
  [mixer]
  nosound=true
  [autoexec]
  @echo off
  mount c "#{out / 'drive'}"
  c:
  RUN.BAT
  exit
CONF
env = { 'SDL_VIDEODRIVER' => 'offscreen', 'SDL_AUDIODRIVER' => 'dummy',
        'XDG_CONFIG_HOME' => (out / 'config').to_s, 'XDG_DATA_HOME' => (out / 'data').to_s,
        'XDG_CACHE_HOME' => (out / 'cache').to_s }
argv = [options.fetch(:emulator), '--noprimaryconf', '--nolocalconf', '--conf', out / 'dosbox.conf', '--exit']
pid = nil
status = nil
begin
  pid = Process.spawn(env, *argv.map(&:to_s), out: (out / 'dosbox.log').to_s, err: [:child, :out], pgroup: true)
  loop do
    waited, status = Process.wait2(pid, Process::WNOHANG)
    break if waited
    if (out / 'drive/DONE.TXT').file?
      Process.kill('INT', -pid) rescue Errno::ESRCH
      _, status = Process.wait2(pid)
      break
    end
    sleep 0.25
  end
ensure
  if pid && !status
    begin
      Process.kill('TERM', -pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
    end
  end
end
images.each_with_index do |entry, i|
  path = out / "drive/P#{i}.TXT"
  entry['output'] = path.file? ? path.read.strip : nil
  entry['dos_exit_zero'] = !(out / "drive/E#{i}.TXT").exist?
  entry['status'] = entry['output'] == 'PASS' && entry['dos_exit_zero'] ? 'pass' : 'fail'
end
passed = (out / 'drive/DONE.TXT').file? && images.all? { |entry| entry['status'] == 'pass' }
File.write(out / 'results.json', JSON.pretty_generate('status' => passed ? 'pass' : 'fail', 'images' => images,
                                                     'emulated_cpu' => '386', 'timeouts_used' => false) + "\n")
puts JSON.pretty_generate(images.map { |entry| entry.slice('model', 'output', 'dos_exit_zero', 'status') })
abort "uname ABI acceptance failed; inspect #{out}" unless passed
