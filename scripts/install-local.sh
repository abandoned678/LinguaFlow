#!/bin/zsh

set -euo pipefail

project_dir=${0:A:h:h}
$project_dir/scripts/build-app.sh release >/dev/null
source_bundle="$project_dir/.build/SentenceAlong.app"
destination_dir="$HOME/Library/Input Methods"
destination_bundle="$destination_dir/SentenceAlong.app"

pkill -x SentenceAlongIME >/dev/null 2>&1 || true
pkill -x SentenceAlongSetup >/dev/null 2>&1 || true
expected_id=com.abandoned678.inputmethod.SentenceAlong
if [[ -L "$destination_dir" || -L "$destination_bundle" ]]; then
  echo "Refusing a symbolic-link installation path" >&2
  exit 65
fi
if [[ -e "$destination_bundle" ]]; then
  actual_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination_bundle/Contents/Info.plist")
  if [[ "$actual_id" != "$expected_id" ]]; then
    echo "Refusing to overwrite a different bundle at $destination_bundle" >&2
    exit 65
  fi
fi
mkdir -p "$destination_dir"
staging_dir=$(mktemp -d "$destination_dir/.sentencealong-install.XXXXXX")
staged_bundle="$staging_dir/SentenceAlong.app"
previous_bundle="$staging_dir/Previous.app"
cleanup_installation() {
  if [[ -e "$previous_bundle" && ! -e "$destination_bundle" ]]; then
    if ! mv "$previous_bundle" "$destination_bundle"; then
      echo "Could not restore the previous bundle at $previous_bundle" >&2
      return
    fi
  fi
  /bin/rm -rf "$staging_dir"
}
trap cleanup_installation EXIT

ditto "$source_bundle" "$staged_bundle"
codesign --verify --deep --strict "$staged_bundle"
if [[ -e "$destination_bundle" ]]; then
  mv "$destination_bundle" "$previous_bundle"
fi
mv "$staged_bundle" "$destination_bundle"
"$destination_bundle/Contents/MacOS/SentenceAlongIME" --install-input-source

echo "Installed: $destination_bundle"
echo "Select 随键译 from the input menu. If missing, check System Settings > Keyboard > Text Input > Edit."
echo "Before translating, open SentenceAlong's input menu and choose 准备本地翻译模型."
