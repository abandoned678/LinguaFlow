#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
bundle=.build/SentenceAlong.app
plist="$bundle/Contents/Info.plist"
[[ $(plutil -extract CFBundleIdentifier raw "$plist") == com.abandoned678.inputmethod.SentenceAlong ]]
[[ $(plutil -extract Configuration raw "$bundle/Contents/Resources/BuildInfo.plist") == release ]]
if plutil -extract IMETestBuild raw "$plist" >/dev/null 2>&1; then exit 1; fi
[[ -z $(find "$bundle" \( -name IMEHost -o -name IMERunner -o -name '*IMETrace*' \) -print) ]]
symbols=$(nm "$bundle/Contents/MacOS/SentenceAlongIME")
[[ "$symbols" != *DebugIMEProbe* && "$symbols" != *IMETrace* ]]
codesign --verify --deep --strict "$bundle"
fixture=sentencealong_fixture.schema.yaml
[[ ! -e "$bundle/Contents/Resources/Rime/$fixture" ]]
debug_bundle=.build/ime-testing/SentenceAlongDebug.app
if [[ -d "$debug_bundle" ]]; then
  [[ $(plutil -extract Configuration raw "$debug_bundle/Contents/Resources/BuildInfo.plist") == debug ]]
  [[ $(plutil -extract CFBundleIdentifier raw "$debug_bundle/Contents/Info.plist") == com.abandoned678.inputmethod.SentenceAlongDebug ]]
  plutil -extract IMETestBuild raw "$debug_bundle/Contents/Info.plist" >/dev/null
  debug_symbols=$(nm "$debug_bundle/Contents/MacOS/SentenceAlongIME")
  [[ "$debug_symbols" == *DebugIMEProbe* ]]
  cmp "Tools/IMETesting/Rime/$fixture" "$debug_bundle/Contents/Resources/Rime/$fixture"
  diff -qr -x "$fixture" -x luna_pinyin_simp.custom.yaml \
    "$bundle/Contents/Resources/Rime" "$debug_bundle/Contents/Resources/Rime"
  # Check resolved schemas after deployment, including Rime's include/patch rules.
  scratch=$(mktemp -d)
  trap '/bin/rm -rf "$scratch"' EXIT
  for profile in daily release; do
    data="$debug_bundle/Contents/Resources/Rime"
    [[ "$profile" != release ]] || data="$bundle/Contents/Resources/Rime"
    mkdir -p "$scratch/$profile/build"
    rime_deployer --build "$scratch/$profile" "$PWD/$data" "$scratch/$profile/build"
  done
  /usr/bin/ruby -ryaml - "$scratch" <<'RUBY'
root = ARGV.fetch(0)
load_config = ->(profile, name) { YAML.load_file(File.join(root, profile, "build", name)) }
daily = load_config.call("daily", "luna_pinyin_simp.schema.yaml")
release = load_config.call("release", "luna_pinyin_simp.schema.yaml")
[daily, release].each { |config| config.delete("__build_info") }
daily.fetch("schema").fetch("dependencies").delete("sentencealong_fixture")
abort "Daily pinyin configuration diverged from Release" unless daily == release
fixture = load_config.call("daily", "sentencealong_fixture.schema.yaml")
abort "Fixture uses the personal dictionary" unless fixture.dig("translator", "enable_user_dict") == false
abort "Fixture reads custom phrases" if fixture.dig("engine", "translators").include?("table_translator@custom_phrase")
schemas = load_config.call("daily", "default.yaml").fetch("schema_list")
abort "Synthetic schema exposed in daily menu" if schemas.any? { |entry| entry["schema"] == "sentencealong_fixture" }
RUBY
  codesign --verify --deep --strict "$debug_bundle"
fi
# When available, check the ordinary (non-test) debug executable as well.
if [[ -x .build/debug/InputMethod ]]; then
  ordinary_symbols=$(nm .build/debug/InputMethod)
  [[ "$ordinary_symbols" != *DebugIMEProbe* ]]
fi
echo "Release isolation passed"
