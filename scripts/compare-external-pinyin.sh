#!/bin/zsh
# Run from an unlocked macOS desktop with Sogou and system Simplified Pinyin enabled.
set -euo pipefail
project=${0:A:h:h}
temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT
bundle="$temp_dir/PinyinComparison.app/Contents"
mkdir -p "$bundle/MacOS"
plutil -create xml1 "$bundle/Info.plist"
plutil -insert CFBundleIdentifier -string local.sentencealong.pinyincomparison "$bundle/Info.plist"
plutil -insert CFBundleName -string "随键译候选对照" "$bundle/Info.plist"
plutil -insert CFBundleExecutable -string PinyinComparison "$bundle/Info.plist"
plutil -insert CFBundlePackageType -string APPL "$bundle/Info.plist"
swiftc "$project/Tools/IMETesting/Quality/ExternalCandidates.swift" -o "$bundle/MacOS/PinyinComparison"
codesign --force --sign - "$temp_dir/PinyinComparison.app"
"$bundle/MacOS/PinyinComparison" "$project/Tests/Fixtures/pinyin-quality.tsv"
