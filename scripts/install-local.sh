#!/bin/zsh

set -euo pipefail

project_dir=${0:A:h:h}
$project_dir/scripts/build-app.sh release >/dev/null
source_bundle="$project_dir/.build/LinguaFlowDev.app"
english_source_bundle="$project_dir/.build/LinguaFlowDevEnglish.app"
destination_dir="$HOME/Library/Input Methods"
destination_bundle="$destination_dir/LinguaFlowDev.app"
english_destination_bundle="$destination_dir/LinguaFlowDevEnglish.app"

pkill -x LinguaFlowDevIME >/dev/null 2>&1 || true
pkill -x LinguaFlowDevEnglishIME >/dev/null 2>&1 || true
pkill -x LinguaFlowDevSetup >/dev/null 2>&1 || true
mkdir -p "$destination_dir"
ditto "$source_bundle" "$destination_bundle"
ditto "$english_source_bundle" "$english_destination_bundle"
codesign --verify --deep --strict "$destination_bundle"
codesign --verify --deep --strict "$english_destination_bundle"
"$destination_bundle/Contents/MacOS/LinguaFlowDevIME" --register-input-source
"$english_destination_bundle/Contents/MacOS/LinguaFlowDevEnglishIME" --register-input-source

echo "Installed: $destination_bundle"
echo "Installed: $english_destination_bundle"
echo "Next: System Settings > Keyboard > Text Input > Edit, then add LinguaFlow Dev 中文 and LinguaFlow Dev English."
echo "Before translating, open LinguaFlow's input menu and choose 准备本地中英翻译."
