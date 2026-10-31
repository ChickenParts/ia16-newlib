# DOS MZ segment packing uses LLD section classes. Whole functions and objects
# spill into the next 64KB segment; unlike hash bins this cannot fail merely
# because unrelated names collide. VMAs are segment offsets, LMAs are packed
# physical load-image addresses. The DOS conventional-memory limit bounds
# resident images independently of this maximum number of candidate segments.
module IA16ClangSysroot
  def self.dos_clang_mz_script(template)
    count = 16
    regions = %w[near_code near_data].map { |name| "  #{name} : ORIGIN = 0, LENGTH = 0x10000" }
    regions << '  metadata : ORIGIN = 0, LENGTH = 0x100000'
    %w[far_code far_data].each do |kind|
      count.times { |i| regions << "  #{kind}_#{i} : ORIGIN = 0, LENGTH = 0x10000" }
    end
    replacements = { '@MEMORY@' => "MEMORY {\n#{regions.join("\n")}\n}" }
    previous = '.text'
    { '@FAR_CODE@' => ['fartext', 'far_code', 'far_text'],
      '@FAR_DATA@' => ['fardata', 'far_data', 'far_data'] }.each do |token, (section, region, klass)|
      replacements[token] = count.times.map do |i|
        name = ".#{section}.#{i}"
        lma = "ALIGN(LOADADDR(#{previous}) + SIZEOF(#{previous}), 16)"
        previous = name
        # The initialized DGROUP null word follows every far bank, so the MZ
        # image includes their zero-filled gaps without stealing a payload byte.
        "  #{name} 0 : AT(#{lma}) { CLASS(#{klass}) } > #{region}_#{i}"
      end.join("\n")
    end
    replacements['@DATA_LMA@'] = "ALIGN(LOADADDR(#{previous}) + SIZEOF(#{previous}), 16)"
    replacements.reduce(template) { |script, (token, text)| script.gsub(token, text) }
  end
end
