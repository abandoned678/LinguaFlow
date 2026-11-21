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
# When available, check the ordinary (non-test) debug executable as well.
if [[ -x .build/debug/InputMethod ]]; then
  ordinary_symbols=$(nm .build/debug/InputMethod)
  [[ "$ordinary_symbols" != *DebugIMEProbe* ]]
fi
echo "Release isolation passed"
