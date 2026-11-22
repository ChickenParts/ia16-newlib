#!/usr/bin/env ruby

require 'minitest/autorun'
require 'open3'
require 'pathname'

class IA16DOSStartupSourceTest < Minitest::Test
  IA16 = Pathname(__FILE__).realpath.dirname.parent.parent

  def test_preflight_covers_all_clang_profiles_before_runtime_mutations
    source = File.read(IA16 / 'dos-models-crt0.S')
    preflight = source.index('.Lia16_startup_preflight:')
    refute_nil preflight, 'Clang startup has no bounded preflight entry'
    macro_start = source.index('.macro IA16_STARTUP_FAIL_IF opcode')
    macro_end = source.index('.endm', macro_start)
    failure_macro = source[macro_start...macro_end]
    assert_includes failure_macro, '\\opcode .Lia16_startup_fail\\@'
    assert_includes failure_macro, 'jmp .Lia16_startup_safe\\@'
    assert_includes failure_macro, 'jmp .Lia16_startup_refuse'
    %w[TINY SMALL MEDIUM COMPACT LARGE].each do |model|
      assert_match(/defined\(#{model}\)/, source,
                   "preflight model gate omits #{model.downcase}")
    end
    entry_check = source.index('.Lia16_startup_entry_check:')
    version_query = source.index(/\bint\s+\$0x21/)
    assert_operator entry_check, :<, version_query,
      'entry stack guard must precede the DOS version query'
    mutations = {
      'DOS block resize' => source.index(/\bmovb\s+\$0x4a/),
      'BSS clear' => source.index(/\bmovw\s+\$__sbss\b/),
      'environment copy' => source.index(/\brep\s+movsb/),
      'environment pointer vector' => source.index('.Lpush_env_pointers:')
    }
    mutations.each do |name, index|
      refute_nil index, "test cannot find #{name} mutation"
      assert_operator preflight, :<, index,
        "preflight must precede #{name}"
    end
    assert_match(/movw\s+\$0x4cff,\s*%ax[\s\S]*?int\s+\$0x21/, source,
                 'refusal must terminate with status 255')
    continuation = source.index('.Lia16_startup_continue:')
    successful_preflight = source[preflight...continuation]
    assert_match(/movw\s+%ds,\s*%ax[\s\S]*?movw\s+%ax,\s*%es/,
                 successful_preflight,
                 'successful preflight must restore ES to the PSP before tiny MCB resize')
    assert_match(/cmpw\s+\$1,\s*%cx[\s\S]*?movw\s+\$260,\s*%cx[\s\S]*?\.Lia16_path_scan:/,
                 successful_preflight,
                 'DOS 3+ trailer count must be distinguished from the bounded path scan')
    path_scan = successful_preflight[
      successful_preflight.index('.Lia16_path_scan:')...successful_preflight.index('.Lia16_path_done:')]
    refute_match(/movw\s+%di,\s*%bx/, path_scan,
                 'path accounting must preserve the environment-entry count in BL')
    assert_match(/movw\s+\$260,\s*%ax[\s\S]*?subw\s+%cx,\s*%ax/,
                 path_scan,
                 'path cost must come from the bounded scan counter')
  end

  def test_clang_linker_profiles_export_stack_boundary_and_reserve
    tiny_template = IA16 / 'dos-mt.ld.in'
    tiny, tiny_error, tiny_status = Open3.capture3('sh', tiny_template.to_s,
                                                    '-nostdlib', '-mclang-runtime')
    assert tiny_status.success?, tiny_error
    mz_script = File.read(IA16 / 'dos-clang-mz.ld.in')
    [tiny, mz_script].each do |script|
      assert_includes script, '__ia16_startup_stack_floor'
      assert_includes script, '__ia16_startup_entry_stack_reserve'
      assert_includes script, '__ia16_startup_stack_reserve'
    end
    assert_match(/PROVIDE\(__ia16_startup_stack_top\s*=\s*0\);/, mz_script,
                 'MZ uses the 16-bit zero encoding for its 64KB stack top')

    gcc_tiny, gcc_error, gcc_status = Open3.capture3('sh', tiny_template.to_s,
                                                     '-nostdlib')
    assert gcc_status.success?, gcc_error
    refute_includes gcc_tiny, '__ia16_startup_stack_floor',
      'the legacy GCC linker profile should not gain Clang-only startup symbols'
  end
end
