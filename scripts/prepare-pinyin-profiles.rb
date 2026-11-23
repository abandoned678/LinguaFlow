#!/usr/bin/ruby
# Generate Rime schemas from independent settings. All variants share the Luna
# dictionary and learning data; the prism depends only on layout and fuzzy groups.
require "yaml"

destination = ARGV.fetch(0)
def save_yaml(destination, name, document)
  File.write(File.join(destination, name), YAML.dump(document))
end

short_finals = {
  "ai"=>"d", "ei"=>"w", "ui"=>"v", "ao"=>"c", "ou"=>"z", "iu"=>"q",
  "ie"=>"p", "ue"=>"t", "ve"=>"t", "an"=>"j", "en"=>"f", "in"=>"b",
  "un"=>"y", "ang"=>"h", "eng"=>"g", "ing"=>"k", "ong"=>"s", "iong"=>"s",
  "iang"=>"l", "uang"=>"l", "ia"=>"x", "ua"=>"x", "uai"=>"k", "iao"=>"n",
  "ian"=>"m", "uan"=>"r", "uo"=>"o"
}
flypy = ["xform/^(zh|ch|sh|[bpmfdtnlgkhjqxywrzcs])(.+)$/$1~$2/",
         "xform/^zh~/v~/", "xform/^ch~/i~/", "xform/^sh~/u~/",
         "xform/^ang$/ah/", "xform/^eng$/eg/", "xform/^([aeo])$/$1$1/"]
short_finals.each { |final, key| flypy << "xform/~#{final}$/#{key}/" }
flypy << "xform/~//"
common = {
  "engine/translators/+" => ["table_translator@sjy_phrases", "table_translator@sjy_weighted"],
  "sjy_weighted" => {
    "dictionary" => "", "user_dict" => "sjy_weighted", "db_class" => "stabledb",
    "enable_completion" => false, "enable_sentence" => false, "initial_quality" => 3
  },
  "sjy_phrases" => {
    "dictionary" => "", "user_dict" => "sjy_personal", "db_class" => "stabledb",
    "enable_completion" => false, "enable_sentence" => false, "initial_quality" => 10
  }
}
# Stable table candidates are literal personal phrases, including the upstream
# custom_phrase table. Learned script candidates still use the usual filters.
%w[zh_hans zh_hant_hk zh_hant_tw].each do |filter|
  common["#{filter}/excluded_types/+"] = ["user_table"]
end
profiles = []
["full", "flypy"].each do |layout|
  (0..7).each do |mask|
    initials = %w[z c s].each_with_index.select { |_, i| mask[i] == 1 }.map(&:first)
    prism = "sjy_#{layout}#{initials.join}"
    fuzzy = initials.flat_map { |letter| ["derive/^#{letter}h/#{letter}/", "derive/^#{letter}([^h])/#{letter}h$1/"] }
    [true, false].each do |learning|
      next if layout == "full" && initials.empty? && learning
      name = learning ? prism : "#{prism}_private"
      profiles << name
      patch = common.merge(
        "switches/@2/reset" => 1,
        "translator/prism" => (layout == "full" && initials.empty? ? "luna_pinyin_simp" : prism),
        "translator/enable_user_dict" => learning
      )
      if layout == "flypy"
        patch["speller/algebra"] = fuzzy + flypy
      elsif !fuzzy.empty?
        patch["speller/algebra/+"] = fuzzy
      end
      save_yaml(destination, "#{name}.schema.yaml", {"schema" => {"schema_id" => name, "name" => name, "version" => "1"},
                "__include" => "luna_pinyin.schema:/", "__patch" => patch})
    end
  end
end
# This tiny schema releases the native dictionary handles held by idle sessions
# before reloading phrase edits or clearing explicitly confirmed learning data.
save_yaml(destination, "sjy_idle.schema.yaml", {
  "schema" => {"schema_id"=>"sjy_idle", "name"=>"sjy_idle", "version"=>"1"},
  "engine" => {"processors"=>[], "segmentors"=>[], "translators"=>[]}
})
profiles << "sjy_idle"
save_yaml(destination, "luna_pinyin_simp.custom.yaml", {"patch"=>common.merge("schema/dependencies/+"=>profiles)})
