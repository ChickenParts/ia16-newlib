#!/usr/bin/env ruby
require 'digest'
require 'json'
require 'open3'
require 'optparse'
require 'pathname'
require 'shellwords'

options = {}
OptionParser.new do |parser|
  parser.on('--profile PATH') { |value| options[:profile] = Pathname(value).realpath }
  parser.on('--out DIR') { |value| options[:out] = Pathname(value).expand_path }
end.parse!
abort 'required: --profile PATH --out DIR' unless options.keys.sort == %i[out profile]
out = options[:out]
abort "output is not empty: #{out}" if out.exist? && !out.children.empty?
out.mkpath
source = Pathname(__dir__).realpath
escape = ->(path) { path.to_s.gsub('$', '$$').gsub(' ', '$ ').gsub(':', '$:') }
graph = ['rule run', '  command = $cmd']
images = []
batch = ['@echo off']
%w[tiny small medium compact large].each_with_index do |model, i|
  extension = model == 'tiny' ? 'COM' : 'EXE'
  abort_image, create_image = %w[AB CR].map { |name| out / "#{name}#{i}.#{extension}" }
  abort_object, create_object, hook_object = %w[abort create hook].map { |name| out / "#{model}-#{name}.o" }
  jobs = [
    [abort_object, [source / 'abort.c'], ["ia16_clang_#{model}", "-DABORT_FILE=\"A#{i}.TXT\"", '-c', source / 'abort.c', '-o', abort_object]],
    [create_object, [source / 'create.c'], ["ia16_clang_#{model}", '-c', source / 'create.c', '-o', create_object]],
    [hook_object, [source / 'create-hook.S', source.parent.parent / 'call-cvt.h'], ["ia16_clang_#{model}", '-I', source.parent.parent, '-c', source / 'create-hook.S', '-o', hook_object]],
    [abort_image, [abort_object], ["ia16_link_#{model}", abort_object, '-o', abort_image]],
    [create_image, [create_object, hook_object], ["ia16_link_#{model}", create_object, hook_object, '-o', create_image]]
  ]
  jobs.each do |output, inputs, arguments|
    command = ". #{options[:profile].to_s.shellescape} && #{Shellwords.join(arguments.map(&:to_s))}"
    graph += ["build #{escape.call(output)}: run #{inputs.map(&escape).join(' ')} | #{escape.call(options[:profile])}",
              '  cmd = ' + Shellwords.join(['bash', '-e', '-c', command]).gsub('$', '$$')]
  end
  images += [{ model: model, kind: 'abort', path: abort_image.to_s, receipt: "A#{i}.TXT" },
             { model: model, kind: 'create', path: create_image.to_s, receipt: "C#{i}.TXT" }]
  batch += [abort_image.basename.to_s, 'if errorlevel 135 goto fail', "if errorlevel 134 goto ok#{i}",
            'goto fail', ":ok#{i}", "#{create_image.basename} > C#{i}.TXT", 'if errorlevel 1 goto fail']
end
graph += ["build all: phony #{images.map { |row| escape.call(row[:path]) }.join(' ')}", 'default all']
(out / 'build.ninja').write(graph.join("\n") + "\n")
stdout, stderr, status = Open3.capture3('ninja', '-C', out.to_s, 'all')
(out / 'build.log').write(stdout + stderr)
abort "provider probes failed to build: #{out / 'build.log'}" unless status.success?
images.each { |row| row[:sha256] = Digest::SHA256.file(row[:path]).hexdigest }
(out / 'images.json').write(JSON.pretty_generate(images: images) + "\n")
batch += ['echo DONE>DONE.TXT', 'goto end', ':fail', 'echo FAIL>FAIL.TXT', ':end']
(out / 'RUN.BAT').binwrite(batch.join("\r\n") + "\r\n")
puts "Built #{images.length} DOS provider probes"
