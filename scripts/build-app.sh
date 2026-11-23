#!/bin/zsh

set -euo pipefail

project_dir=${0:A:h:h}
configuration=${1:-release}
code_sign_identity=${CODE_SIGN_IDENTITY:--}
app_bundle="$project_dir/.build/SentenceAlong.app"
build_args=(-c "$configuration")
case "$configuration" in
  debug) export SENTENCEALONG_TEST_BUILD=1 ;;
  release) export SENTENCEALONG_TEST_BUILD=0 ;;
  *) echo "Usage: $0 [debug|release]" >&2; exit 64 ;;
esac
if [[ "$configuration" == debug ]]; then
  app_bundle="$project_dir/.build/ime-testing/SentenceAlongDebug.app"
  build_args+=(--scratch-path "$project_dir/.build/ime-testing/swift")
fi
helper_bundle="$app_bundle/Contents/Helpers/SentenceAlongSetup.app"

cd "$project_dir"

if ! brew list --versions librime >/dev/null 2>&1; then
  echo "Missing librime. Install it with: brew install librime" >&2
  exit 1
fi

swift build "${build_args[@]}" --product InputMethod
swift build "${build_args[@]}" --product TranslationSetup
binary_dir=$(swift build "${build_args[@]}" --show-bin-path)

/bin/rm -rf "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS"
mkdir -p "$app_bundle/Contents/Resources/Rime"
mkdir -p "$app_bundle/Contents/Resources/ThirdPartyLicenses"
mkdir -p "$helper_bundle/Contents/MacOS"

cp "$project_dir/Resources/ChineseInputMethod.plist" "$app_bundle/Contents/Info.plist"
cp "$binary_dir/InputMethod" "$app_bundle/Contents/MacOS/SentenceAlongIME"
"$project_dir/scripts/prepare-rime-data.sh" "$app_bundle/Contents/Resources/Rime" >/dev/null
swift "$project_dir/scripts/make-icon.swift" "$app_bundle/Contents/Resources/InputSourceIconTemplate.tiff"
cp "$project_dir/LICENSE" "$app_bundle/Contents/Resources/LICENSE.txt"
cp "$project_dir/THIRD_PARTY_NOTICES.md" "$app_bundle/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$project_dir/installer/ThirdPartyLicenses"/* \
  "$app_bundle/Contents/Resources/ThirdPartyLicenses/"
cp "$project_dir/Vendor/rime-prelude/LICENSE" \
  "$app_bundle/Contents/Resources/ThirdPartyLicenses/RimePrelude-LICENSE.txt"
cp "$project_dir/Vendor/rime-luna-pinyin/LICENSE" \
  "$app_bundle/Contents/Resources/ThirdPartyLicenses/LunaPinyin-LICENSE.txt"
cp "$project_dir/Vendor/rime-essay/LICENSE" \
  "$app_bundle/Contents/Resources/ThirdPartyLicenses/RimeEssay-LICENSE.txt"

cp "$project_dir/Resources/TranslationSetup.plist" "$helper_bundle/Contents/Info.plist"
if [[ "$configuration" == debug ]]; then
  test_id=com.abandoned678.inputmethod.SentenceAlongDebug
  for key in CFBundleIdentifier TISInputSourceID; do
    plutil -replace "$key" -string "$test_id" "$app_bundle/Contents/Info.plist"
  done
  plutil -replace InputMethodConnectionName -string "${test_id}_Connection" "$app_bundle/Contents/Info.plist"
  # TIS uses CFBundleName for this single-mode input source in the keyboard picker.
  for key in CFBundleName CFBundleDisplayName; do
    plutil -replace "$key" -string "随键译 Debug" "$app_bundle/Contents/Info.plist"
  done
  plutil -insert IMETestBuild -string "$(uuidgen)" "$app_bundle/Contents/Info.plist"
  plutil -replace CFBundleIdentifier -string "$test_id.Setup" "$helper_bundle/Contents/Info.plist"
  plutil -replace CFBundleURLTypes.0.CFBundleURLSchemes.0 -string sentencealong-debug-settings "$helper_bundle/Contents/Info.plist"
  # Deploy the synthetic schema as a dependency, outside the user's schema list.
  cp "$project_dir/Tools/IMETesting/Rime/sentencealong_fixture.schema.yaml" "$app_bundle/Contents/Resources/Rime/"
  /usr/bin/ruby -ryaml -e 'file = ARGV.fetch(0); config = YAML.load_file(file)
    config.fetch("patch").fetch("schema/dependencies/+") << "sentencealong_fixture"
    File.write(file, YAML.dump(config))' "$app_bundle/Contents/Resources/Rime/luna_pinyin_simp.custom.yaml"
fi
cp "$binary_dir/TranslationSetup" "$helper_bundle/Contents/MacOS/SentenceAlongSetup"

"$project_dir/scripts/embed-rime-runtime.sh" "$app_bundle" >/dev/null

# The source targets can compile for macOS 26. The assembled artifact must
# also satisfy the load commands in the actual bundled dependencies.
autoload -Uz is-at-least
minimum_system=
for binary in "$app_bundle/Contents/MacOS/SentenceAlongIME" \
              "$helper_bundle/Contents/MacOS/SentenceAlongSetup" \
              "$app_bundle"/Contents/Frameworks/*.dylib; do
  binary_minimum=$(/usr/bin/otool -l "$binary" | /usr/bin/awk '
    $1 == "cmd" { command = $2 }
    command == "LC_BUILD_VERSION" && $1 == "minos" { if (!found++) print $2 }
    command == "LC_VERSION_MIN_MACOSX" && $1 == "version" { if (!found++) print $2 }
  ')
  if [[ -z "$binary_minimum" ]]; then
    echo "Cannot determine macOS minimum for $binary" >&2
    exit 65
  fi
  if [[ -z "$minimum_system" ]] || is-at-least "$minimum_system" "$binary_minimum"; then
    minimum_system=$binary_minimum
  fi
done
for info_plist in "$app_bundle/Contents/Info.plist" "$helper_bundle/Contents/Info.plist"; do
  /usr/bin/plutil -replace LSMinimumSystemVersion -string "$minimum_system" "$info_plist"
done

build_info="$app_bundle/Contents/Resources/BuildInfo.plist"
app_info="$app_bundle/Contents/Info.plist"
source_commit=$(git rev-parse --verify HEAD 2>/dev/null || echo unknown)
source_dirty=true
if [[ "$source_commit" != unknown ]] && [[ -z "$(git status --porcelain)" ]]; then
  source_dirty=false
fi
embedded_versions=$(
  for library in "$app_bundle"/Contents/Frameworks/*.dylib; do
    /usr/bin/otool -L "$library" | /usr/bin/awk -v name="${library:t}" '
      NR == 2 { sub(/^.*current version /, ""); sub(/\).*$/, ""); print name " " $0 }
    '
  done
)
formula_versions=$(brew list --versions librime opencc 2>/dev/null || true)
dictionary_revisions=$(git submodule status 2>/dev/null || true)
/usr/bin/plutil -create xml1 "$build_info"
/usr/bin/plutil -insert Version -string "$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$app_info")" "$build_info"
/usr/bin/plutil -insert Build -string "$(/usr/bin/plutil -extract CFBundleVersion raw "$app_info")" "$build_info"
/usr/bin/plutil -insert MinimumSystem -string "$minimum_system" "$build_info"
/usr/bin/plutil -insert Commit -string "$source_commit" "$build_info"
/usr/bin/plutil -insert WorkingTreeChanges -bool "$source_dirty" "$build_info"
/usr/bin/plutil -insert Configuration -string "$configuration" "$build_info"
/usr/bin/plutil -insert BundledLibraries -string "$embedded_versions" "$build_info"
/usr/bin/plutil -insert BuildFormulas -string "$formula_versions" "$build_info"
/usr/bin/plutil -insert DictionaryRevisions -string "$dictionary_revisions" "$build_info"
/usr/bin/plutil -lint "$build_info" >/dev/null

sign_item() {
  local item=$1
  if [[ "$code_sign_identity" == "-" ]]; then
    codesign --force --sign - "$item"
  else
    codesign --force --options runtime --timestamp --sign "$code_sign_identity" "$item"
  fi
}

for library in "$app_bundle"/Contents/Frameworks/*.dylib; do
  sign_item "$library"
done
sign_item "$helper_bundle"
sign_item "$app_bundle"

plutil -lint "$app_bundle/Contents/Info.plist"
plutil -lint "$helper_bundle/Contents/Info.plist"
codesign --verify --deep --strict "$app_bundle"

echo "$app_bundle"
