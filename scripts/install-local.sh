#!/bin/zsh

set -euo pipefail

project_dir=${0:A:h:h}
source "$project_dir/scripts/local-bundle-transaction.sh"

source_bundle="$project_dir/.build/SentenceAlong.app"
destination_bundle="$HOME/Library/Input Methods/SentenceAlong.app"
system_bundle="/Library/Input Methods/SentenceAlong.app"
expected_id=com.abandoned678.inputmethod.SentenceAlong
register_only=0
[[ ${1:-} != --register-test-build ]] || register_only=1
test_install=0
case "${1:-}" in
  ""|--test-build|--register-test-build) ;;
  *) echo "Unknown installation mode" >&2; exit 64 ;;
esac
if [[ ${1:-} == --test-build || ${1:-} == --register-test-build ]]; then
  test_install=1
  source_bundle="$project_dir/.build/ime-testing/SentenceAlongDebug.app"
  destination_bundle="$HOME/Library/Input Methods/SentenceAlongDebug.app"
  system_bundle=
  expected_id=com.abandoned678.inputmethod.SentenceAlongDebug
fi
previous_source=
previously_enabled=0

verify_staged_bundle() {
  local bundle=$1 minimum
  [[ $(plutil -extract CFBundleIdentifier raw "$bundle/Contents/Info.plist") == "$expected_id" ]] || return 65
  codesign --verify --deep --strict "$bundle" || return $?
  minimum=$(/usr/bin/plutil -extract LSMinimumSystemVersion raw "$bundle/Contents/Info.plist") || return $?
  autoload -Uz is-at-least
  if ! is-at-least "$minimum" "$(/usr/bin/sw_vers -productVersion)"; then
    echo "This build of SentenceAlong requires macOS $minimum." >&2
    return 65
  fi
}

stop_installed_processes() {
  local bundle=$1 pid uid command_line
  while read -r pid uid command_line; do
    if [[ "$uid" == "$EUID" ]] && [[ "$command_line" == "$bundle/Contents/MacOS/SentenceAlongIME" \
       || "$command_line" == "$bundle/Contents/Helpers/SentenceAlongSetup.app/Contents/MacOS/SentenceAlongSetup" ]]; then
      kill "$pid" 2>/dev/null || true
    fi
  done < <(/bin/ps -ax -o pid= -o uid= -o comm=)
}

prepare_for_swap() {
  local bundle=$1 actual_id
  if [[ -e "$bundle" ]]; then
    actual_id=$(/usr/bin/plutil -extract CFBundleIdentifier raw "$bundle/Contents/Info.plist") || return $?
    if [[ "$actual_id" != "$expected_id" ]]; then
      echo "Refusing to overwrite a different bundle at $bundle" >&2
      return 65
    fi
    previous_source="$bundle/Contents/MacOS/SentenceAlongIME"
  elif [[ -n "$system_bundle" && -x "$system_bundle/Contents/MacOS/SentenceAlongIME" ]]; then
    previous_source="$system_bundle/Contents/MacOS/SentenceAlongIME"
  fi
  if [[ -n "$previous_source" ]] && "$previous_source" --verify-input-source >/dev/null 2>&1; then
    previously_enabled=1
  fi
  stop_installed_processes "$bundle"
}

activate_bundle() {
  if (( test_install )); then
    local registrar=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    "$registrar" -f "$1" || return $?
    local binary="$1/Contents/MacOS/SentenceAlongIME"
    "$binary" --register-input-source || return $?
    if (( register_only && ! previously_enabled )); then return 0; fi
    local attempt
    for attempt in {1..5}; do
      if "$binary" --enable-input-source && "$binary" --verify-input-source; then return 0; fi
      sleep 1
    done
    return 1
  fi
  "$1/Contents/MacOS/SentenceAlongIME" --install-input-source || return $?
  "$project_dir/scripts/check-installed-input-sources.swift" --local
}

undo_new_activation() {
  if (( ! previously_enabled )); then
    "$1/Contents/MacOS/SentenceAlongIME" --disable-input-source
  fi
}

restore_registration() {
  if [[ -n "$previous_source" ]]; then
    if (( previously_enabled )); then
      "$previous_source" --install-input-source
    else
      "$previous_source" --register-input-source
    fi
  fi
}

if (( ! test_install )); then
  "$project_dir/scripts/build-app.sh" release >/dev/null
fi
replace_local_bundle "$source_bundle" "$destination_bundle"

echo "Installed: $destination_bundle"
if (( test_install )); then
  echo "Debug ID: $expected_id. Enable 随键译 Debug in Keyboard settings if necessary."
  exit 0
fi
echo "Select 随键译 from the input menu. If missing, check System Settings > Keyboard > Text Input > Edit."
echo "Before translating, open SentenceAlong's input menu and choose 准备本地翻译模型."
