#!/bin/zsh

set -euo pipefail

project_dir=${0:A:h:h}
$project_dir/scripts/build-app.sh release >/dev/null
source_bundle="$project_dir/.build/LinguaFlowDev.app"
destination_dir="$HOME/Library/Input Methods"
destination_bundle="$destination_dir/LinguaFlowDev.app"

pkill -x LinguaFlowDevIME >/dev/null 2>&1 || true
pkill -x LinguaFlowDevSetup >/dev/null 2>&1 || true
expected_id=com.abandoned678.inputmethod.LinguaFlowDev
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
"$destination_bundle/Contents/MacOS/LinguaFlowDevIME" --install-input-source

echo "Installed: $destination_bundle"
echo "Next: System Settings > Keyboard > Text Input > Edit, then add LinguaFlow Dev 中文."
echo "Before translating, open LinguaFlow's input menu and choose 准备本地中英翻译."
