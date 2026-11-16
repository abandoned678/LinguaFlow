#!/bin/zsh

set -euo pipefail

project_dir=${0:A:h:h}
configuration=${1:-release}
code_sign_identity=${CODE_SIGN_IDENTITY:--}
app_bundle="$project_dir/.build/SentenceAlong.app"
helper_bundle="$app_bundle/Contents/Helpers/SentenceAlongSetup.app"

cd "$project_dir"

if ! brew list --versions librime >/dev/null 2>&1; then
  echo "Missing librime. Install it with: brew install librime" >&2
  exit 1
fi

swift build -c "$configuration" --product InputMethod
swift build -c "$configuration" --product TranslationSetup
binary_dir=$(swift build -c "$configuration" --show-bin-path)

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
