#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
out="$PWD/.build/ime-testing"
args=(--scratch-path "$out/swift" -c debug)
export SENTENCEALONG_TEST_BUILD=1
swift build "${args[@]}" --product IMERunner
swift build "${args[@]}" --product IMEHost
bin=$(swift build "${args[@]}" --show-bin-path)
mkdir -p "$out/IMEHost.app/Contents/MacOS"
cp Tools/IMETesting/Host/Info.plist "$out/IMEHost.app/Contents/Info.plist"
cp "$bin/IMEHost" "$out/IMEHost.app/Contents/MacOS/"
cp "$bin/IMERunner" "$out/IMERunner"
codesign --force --sign - "$out/IMEHost.app"
