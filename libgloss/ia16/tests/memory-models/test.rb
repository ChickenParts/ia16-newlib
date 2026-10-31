#!/usr/bin/env ruby
# Check that each frontend memory model has a distinct, matching DOS link profile.

require 'minitest/autorun'
require 'open3'
require 'pathname'
require_relative '../../tools/build-clang-sysroot'

class IA16DOSMemoryModelScriptsTest < Minitest::Test
  IA16 = Pathname(__FILE__).realpath.dirname.parent.parent
  PROFILES = {
    'tiny' => { model_flag: nil, letter: 't', startup: 'dos-t-c0.o', bsp: 'libdos-t.a',
                template: 'dos-mt.ld.in', image: 'COM' },
    'small' => { model_flag: nil, letter: 's', startup: 'dos-s-c0.o', bsp: 'libdos-s.a',
                 template: 'dos-clang-mz.ld.in', image: 'MZ' },
    'medium' => { model_flag: 'medium', letter: 'm', startup: 'dos-m-c0.o', bsp: 'libdos-m.a',
                  template: 'dos-clang-mz.ld.in', image: 'MZ' },
    'compact' => { model_flag: 'compact', letter: 'c', startup: 'dos-c-c0.o', bsp: 'libdos-c.a',
                   template: 'dos-clang-mz.ld.in', image: 'MZ' },
    'large' => { model_flag: 'large', letter: 'l', startup: 'dos-l-c0.o', bsp: 'libdos-l.a',
                 template: 'dos-clang-mz.ld.in', image: 'MZ' }
  }.freeze

  def test_every_frontend_model_generates_a_distinct_matching_dos_profile
    PROFILES.each do |model, profile|
      if profile.fetch(:image) == 'COM'
        script, stderr, status = Open3.capture3('sh', (IA16 / profile.fetch(:template)).to_s,
                                                '-nostdlib', '-mclang-runtime')
        assert status.success?, "#{model} linker script generation failed: #{stderr}"
        assert(script.include?('OUTPUT_FORMAT(binary)'), "#{model}: COM script is not binary output")
      else
        script = File.read(IA16 / profile.fetch(:template))
        assert(script.include?('ENTRY(_start)'), "#{model}: MZ script has no CRT entry")
        assert(script.include?('.ia16_segelf_text_bang'),
          "#{model}: script must place far code-pointer companions at CS")
        assert(script.include?('.ia16_segelf_data_bang __dgroup'),
          "#{model}: script must place far data-pointer companions at DGROUP")
        assert(script.include?('"__dgroup!" = __dgroup'),
          "#{model}: script must define the MZ data-segment base")
        refute(script.include?('OUTPUT_FORMAT(binary)'),
          "#{model}: MZ links must use LLD's native MZ writer")
      end
      config = IA16ClangSysroot::MODELS.fetch(model.to_sym)
      assert_equal profile.fetch(:startup), config.fetch(:startup),
        "#{model}: profile selects the wrong startup object"
      assert_equal profile.fetch(:bsp), config.fetch(:bsp),
        "#{model}: profile selects the wrong libgloss archive"
      if profile.fetch(:image) == 'COM'
        refute(script.include?('SHORT (0x5a4d)'), "#{model}: COM script must not have an MZ header")
      else
        assert(script.include?('INPUT_SECTION_FLAGS(SHF_ALLOC & SHF_EXECINSTR)'),
          "#{model}: script must keep executable aliases in the code segment")
      end
      if profile.fetch(:image) == 'MZ'
        assert(script.include?('R_386_SEG16') || script.include?('SEG16'),
          "#{model}: script must preserve IA-16 segmented pointer relocations")
      end
    end
  end

  def test_build_profile_covers_every_frontend_abi_and_preserves_small_compatibility
    models = IA16ClangSysroot::MODELS
    assert_equal %i[tiny small medium compact large], models.keys
    assert_equal [:near, :near],
      [models.fetch(:tiny).fetch(:code_pointers), models.fetch(:tiny).fetch(:data_pointers)]
    assert_equal [:near, :near],
      [models.fetch(:small).fetch(:code_pointers), models.fetch(:small).fetch(:data_pointers)]
    assert_equal [:far, :near],
      [models.fetch(:medium).fetch(:code_pointers), models.fetch(:medium).fetch(:data_pointers)]
    assert_equal [:near, :far],
      [models.fetch(:compact).fetch(:code_pointers), models.fetch(:compact).fetch(:data_pointers)]
    assert_equal [:far, :far],
      [models.fetch(:large).fetch(:code_pointers), models.fetch(:large).fetch(:data_pointers)]
    assert_equal 'lib/baremetal/libclang_rt.builtins-ia16.a',
      IA16ClangSysroot.builtins_relative_path(:small)
    %i[tiny medium compact large].each do |model|
      assert_equal "lib/baremetal/#{model}/libclang_rt.builtins-ia16.a",
        IA16ClangSysroot.builtins_relative_path(model)
    end
  end

  def test_far_code_crt_registers_far_cleanup_and_walks_four_byte_callback_entries
    crt = File.read(IA16 / 'dos-models-crt0.S')
    assert_includes crt, "movw\t$0, %ax\n\tpushw\t%ax"
    assert_includes crt, 'CALL_ (atexit)'
    assert_includes crt, "lcall\t*%ss:(%si)"
    assert_match(/__IA16_CMODEL_IS_FAR_TEXT[\s\S]*?\n\tlret\n/, crt)
  end

  def test_clang_far_calls_use_the_assembler_segment_relocation_once
    call_cvt = File.read(IA16 / 'call-cvt.h')
    assert_match(/#\s*if defined\(__clang__\) && defined\(__ELF__\)[\s\S]*?#\s+define JMP_\(func\)\s+ljmp \$0, \$func[\s\S]*?#\s+define CALL_\(func\)\s+lcall \$0, \$func/, call_cvt,
      'Clang IA-16 far calls already emit SEG16; adding SEG_RELOC_ duplicates MZ loader relocations')
  end

  def test_far_data_syscalls_pass_offsets_separately_from_selectors
    {
      'dos-access.c' => ['FP_OFF (path)'],
      'dos-chmod.c' => ['FP_OFF (path)'],
      'dos-openr.c' => ['FP_OFF(pathname)'],
      'dos-statr.c' => ['FP_OFF(path)'],
      'dos-getcwd-impl.c' => ['FP_OFF (buf + 3)']
    }.each do |filename, tokens|
      source = File.read(IA16 / filename)
      tokens.each do |token|
        assert_includes source, token,
          "#{filename}: far data pointers need a 16-bit offset operand for DOS INT 21h"
      end
    end
  end

  def test_far_data_heap_and_realpath_keep_pointer_widths_consistent
    sbrk = File.read(IA16 / 'dos-sbrkr.c')
    realpath = File.read(IA16 / 'dos-realpath.c')
    assert_match(/_sbrk_r\s*\(struct _reent \*reent, ptrdiff_t incr\)/, sbrk)
    assert_includes sbrk, 'FP_OFF (heap_end)'
    assert_includes realpath, 'end_offset'
  end

  def test_far_data_write_syscall_passes_far_buffer_to_dos
    writer = File.read(IA16 / 'dos-writer.S')
    assert_match(/#if defined\(__FAR_DATA__\)[\s\S]*?ENTER_BX_\(12\)[\s\S]*?FAR_ADJ__\+12\(%bx\), %cx[\s\S]*?FAR_ADJ__\+10\(%bx\), %ax[\s\S]*?movw\s+%ax, %ds[\s\S]*?RET_\(12\)/, writer)
  end

  def test_configured_makefile_variable_reader_expands_recursive_source_lists
    variables = IA16ClangSysroot::MakeVariables.new(<<~MAKE)
      common = libc/first.c libc/second.S
      enabled = $(common) libc/third.c
      # disabled = libc/not-built.c
      libc_a_SOURCES = $(enabled) libc/header.h
    MAKE
    assert_equal %w[libc/first.c libc/second.S libc/third.c libc/header.h],
      variables.words('libc_a_SOURCES')
  end
end
