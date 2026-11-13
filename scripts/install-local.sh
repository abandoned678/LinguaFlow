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
ditto "$source_bundle" "$destination_bundle"
codesign --verify --deep --strict "$destination_bundle"
"$destination_bundle/Contents/MacOS/SentenceAlongIME" --install-input-source

echo "Installed: $destination_bundle"
echo "Select 随键译 from the input menu. If missing, check System Settings > Keyboard > Text Input > Edit."
echo "Before translating, open SentenceAlong's input menu and choose 准备本地中英翻译."
