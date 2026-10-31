#!/usr/bin/env ruby
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'pathname'
require 'shellwords'
options = {}
OptionParser.new do |parser|
  parser.banner = 'Usage: build.rb --tool-root DIR --runtime-prefix DIR --out NEW_DIR'
  %i[tool_root runtime_prefix out].each do |name|
    parser.on("--#{name.to_s.tr('_','-')} DIR") { |value| options[name] = Pathname(value).expand_path }
  end
end.parse!
abort 'missing --tool-root, --runtime-prefix or --out' unless options.keys.sort == %i[out runtime_prefix tool_root]
out = options.fetch(:out)
abort "output already exists: #{out}" if out.exist?
[__dir__, *options.values].each { |p| abort 'paths cannot contain whitespace or $' if p.to_s.match?(/[\s$]/) }
out.mkpath
source = Pathname(__dir__).realpath
ia16 = source.parent.parent
tools = options.fetch(:tool_root) / 'bin'
resource, error, status = Open3.capture3((tools / 'clang').to_s, '-print-resource-dir')
abort error unless status.success?
lines = ['ninja_required_version = 1.3']
images = []
%w[tiny small medium compact large].each_with_index do |model, i|
  root = options.fetch(:runtime_prefix) / 'ia16-pc-msdos' / model
  base = [tools / 'clang', '--target=ia16-pc-msdos', '-march=8086', "-mmemory-model=#{model}",
          '-Oz', '-ffreestanding', '-fno-builtin', '-ffunction-sections', '-fdata-sections',
          '-nostdinc', '-isystem', root / 'include', '-isystem', root / 'include/newlib',
          '-isystem', Pathname(resource.strip) / 'include', '-I', ia16]
  objects = [source / 'probe.c', source / 'hook.S', ia16 / 'dos-uname.c', ia16 / 'dos-uname-impl.S'].map.with_index do |input, n|
    output = out / "#{model}-#{n}.o"
    rule = "cc_#{i}_#{n}"
    lines += ["rule #{rule}", "  command = #{Shellwords.join((base + ['-c', input, '-o', output]).map(&:to_s))}",
              "build #{output}: #{rule} #{input}"]
    output
  end
  image = out / "P#{i}.EXE"
  rule = "link_#{i}"
  argv = [tools / 'ld.lld', '-m', 'elf_ia16', '--oformat=mz', '--gc-sections', '-T', source / 'layout.ld', *objects, '-o', image]
  lines += ["rule #{rule}", "  command = #{Shellwords.join(argv.map(&:to_s))}", "build #{image}: #{rule} #{objects.join(' ')}"]
  images << { 'model' => model, 'path' => image.to_s, 'expected' => 'PASS' }
end
lines += ["build all: phony #{images.map { |i| i.fetch('path') }.join(' ')}", 'default all']
File.write(out / 'build.ninja', lines.join("\n") + "\n")
File.open(out / 'build.log', 'w') do |log|
  pid = Process.spawn('ninja', '-C', out.to_s, '-j4', 'all', out: log, err: [:child, :out])
  _, status = Process.wait2(pid)
  abort "build failed; inspect #{out / 'build.log'}" unless status.success?
end
images.each { |entry| entry['sha256'] = Digest::SHA256.file(entry.fetch('path')).hexdigest }
File.write(out / 'images.json', JSON.pretty_generate(images) + "\n")
batch = ['@echo off']
images.each_with_index { |entry, i| batch += ["P#{i}.EXE > P#{i}.TXT", 'if errorlevel 1 goto fail'] }
batch += ['echo DONE>DONE.TXT', 'goto end', ':fail', 'echo FAIL>FAIL.TXT', ':end']
File.binwrite(out / 'RUN.BAT', batch.join("\r\n") + "\r\n")
puts "Built #{images.length} successful INT21 extension ABI probes in #{out}"
