#!/usr/bin/env ruby
require 'fileutils'
require 'open3'
require 'optparse'
require 'pathname'
require 'shellwords'
require 'json'
require 'digest'
options = {}
OptionParser.new do |p|
  p.on('--profile PATH') { |v| options[:profile] = Pathname(v).realpath }
  p.on('--tools DIR') { |v| options[:tools] = Pathname(v).realpath / 'bin' }
  p.on('--out DIR') { |v| options[:out] = Pathname(v).expand_path }
end.parse!
abort 'required: --profile PATH --tools DIR --out DIR' unless options.keys.sort == %i[out profile tools]
out = options[:out]
abort "output is not empty: #{out}" if out.exist? && !out.children.empty?
out.mkpath
source = Pathname(__dir__)
images = []
commands = []
%w[tiny small medium compact large].each do |model|
  name = model[0].upcase
  image = out / "#{name}.#{model == 'tiny' ? 'COM' : 'EXE'}"
  object = out / "#{model}.o"
  command = ". #{Shellwords.escape(options[:profile].to_s)} && " \
    "ia16_clang_#{model} -c #{Shellwords.escape((source / 'runtime.c').to_s)} -o #{Shellwords.escape(object.to_s)} && " \
    "ia16_link_#{model} #{Shellwords.escape(object.to_s)} -o #{Shellwords.escape(image.to_s)}"
  commands << command
  stdout, stderr, status = Open3.capture3('bash', '-e', '-c', command)
  abort "#{model}: #{stdout}#{stderr}" unless status.success?
  if %w[compact large].include?(model)
    (0..2).each do |strategy|
      launcher = out / "#{name}#{strategy}.COM"
      args = [options[:tools] / 'clang', '--target=ia16-pc-msdos', '-march=8086', '-mmemory-model=tiny',
              "-DHEAP_STRATEGY=#{strategy}", "-DHEAP_PROGRAM=\"#{image.basename}\"", '-c', source / 'strategy.S', '-o', out / 'strategy.o']
      link = [options[:tools] / 'ld.lld', '-m', 'elf_ia16', '--oformat=binary', '-T', source / 'strategy.ld', out / 'strategy.o', '-o', launcher]
      [args, link].each do |argv|
        commands << argv.map(&:to_s)
        stdout, stderr, status = Open3.capture3(*argv.map(&:to_s))
        abort "#{model}/#{strategy}: #{stdout}#{stderr}" unless status.success?
      end
      images << { model: model, strategy: strategy, image: launcher.basename.to_s,
                  child: image.basename.to_s, sha256: Digest::SHA256.file(launcher).hexdigest,
                  child_sha256: Digest::SHA256.file(image).hexdigest }
    end
  else
    images << { model: model, image: image.basename.to_s, sha256: Digest::SHA256.file(image).hexdigest }
  end
end
batch = "@echo off\r\n" + images.map.with_index do |row, i|
  "#{row[:image]} > P#{i}.TXT\r\nif errorlevel 1 goto fail#{i}\r\ngoto next#{i}\r\n" \
    ":fail#{i}\r\necho FAIL>P#{i}.ERR\r\n:next#{i}\r\n"
end.join + "echo DONE>DONE.TXT\r\n"
File.binwrite(out / 'RUN.BAT', batch)
File.write(out / 'images.json', JSON.pretty_generate(images: images, commands: commands) + "\n")
puts "Built #{images.length} heap acceptance lanes"
