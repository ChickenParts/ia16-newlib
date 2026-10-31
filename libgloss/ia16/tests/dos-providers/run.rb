#!/usr/bin/env ruby
require 'json'
require 'pathname'
abort 'usage: run.rb BUILT_OUTPUT_DIRECTORY [DOSBOX]' unless (1..2).cover?(ARGV.length)
root = Pathname(ARGV.fetch(0)).realpath
images = JSON.parse((root / 'images.json').read).fetch('images')
abort 'guest receipts already exist; use a fresh output directory' if
  (%w[DONE.TXT FAIL.TXT STOP] + images.map { |row| row.fetch('receipt') }).any? { |name| (root / name).exist? }
(root / 'dosbox.conf').write(<<~CONF)
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
  mount c "#{root}"
  c:
  RUN.BAT
  exit
CONF
env = {'SDL_VIDEODRIVER' => 'offscreen', 'SDL_AUDIODRIVER' => 'dummy'}
%w[CONFIG DATA CACHE].each { |name| env["XDG_#{name}_HOME"] = (root / name.downcase).to_s }
pid = Process.spawn(env, ARGV.fetch(1, 'dosbox'), '--set', 'mouse_capture=nomouse', '--set', 'mouse_raw_input=false',
  '--noprimaryconf', '--nolocalconf', '--conf', (root / 'dosbox.conf').to_s,
  '--exit', out: (root / 'guest.log').to_s, err: [:child, :out], pgroup: true)
ownership = {'namespace_pid' => pid, 'state' => 'running'}
(root / 'guest-ownership.json').write(JSON.pretty_generate(ownership) + "\n")
loop do
  waited, = Process.wait2(pid, Process::WNOHANG)
  break if waited
  if %w[DONE.TXT FAIL.TXT STOP].any? { |name| (root / name).exist? }
    begin
      Process.kill('INT', -pid)
    rescue Errno::ESRCH
    end
    Process.wait(pid)
    break
  end
  sleep 0.25
end
ownership['state'] = 'reaped'
(root / 'guest-ownership.json').write(JSON.pretty_generate(ownership) + "\n")
images = images.map do |row|
  receipt = (root / row.fetch('receipt')).file? ? (root / row.fetch('receipt')).read : ''
  passed = case row.fetch('kind')
           when 'abort' then receipt.include?('abort () called')
           when 'create' then receipt.strip == "CX 0000\nPASS create"
           when 'boundary' then receipt.strip == 'PASS boundary'
           end
  puts "#{row.fetch('model')}/#{row.fetch('kind')}: #{passed ? 'PASS' : 'FAIL'}"
  row.merge('pass' => passed, 'receipt_text' => receipt)
end
passed = (root / 'DONE.TXT').exist? && !(root / 'FAIL.TXT').exist? && images.all? { |row| row['pass'] }
(root / 'guest-results.json').write(JSON.pretty_generate(status: passed ? 'pass' : 'fail', images: images) + "\n")
abort "provider guest failed: #{root / 'guest-results.json'}" unless passed
