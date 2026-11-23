#!/bin/zsh
# Run after building both apps. Exercise publication and provenance checks on copies.
set -euo pipefail
project_dir=${0:A:h:h}
scratch=$(mktemp -d)
trap '/bin/rm -rf "$scratch"' EXIT
cd "$scratch"
mkdir -p scripts .build/ime-testing .build/dist Tools/IMETesting/Rime Resources
cp "$project_dir"/scripts/{check-debug-isolation,build-installer}.sh scripts/
cp "$project_dir"/Tools/IMETesting/Rime/*.yaml Tools/IMETesting/Rime/
cp "$project_dir"/Resources/ChineseInputMethod.plist Resources/
git init -q
git -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m fixture
commit=$(git rev-parse HEAD)
release=.build/SentenceAlong.app
debug=.build/ime-testing/SentenceAlongDebug.app

expect_failure() {
  local expected=$1 actual=0
  shift
  "$@" >failure.log 2>&1 || actual=$?
  if (( actual != expected )); then
    cat failure.log >&2
    echo "Expected exit $expected, got $actual: $*" >&2
    exit 1
  fi
}

for product in "$release" "$debug"; do
  /usr/bin/ditto "$project_dir/$product" "$product"
  metadata="$product/Contents/Resources/BuildInfo.plist"
  plutil -replace Commit -string "$commit" "$metadata"
  plutil -replace WorkingTreeChanges -bool false "$metadata"
  codesign --force --sign - "$product"
done
scripts/check-debug-isolation.sh --strict "$commit"
mv "$debug" .build/unused.app
expect_failure 65 scripts/check-debug-isolation.sh --strict
mv .build/unused.app "$debug"
metadata="$debug/Contents/Resources/BuildInfo.plist"
plutil -replace WorkingTreeChanges -bool true "$metadata"
expect_failure 65 scripts/check-debug-isolation.sh --strict
plutil -replace WorkingTreeChanges -bool false "$metadata"
plutil -replace Commit -string older "$metadata"
expect_failure 65 scripts/check-debug-isolation.sh --strict

# Fail the Release build after installer setup. An existing published package must survive.
print -l '#!/bin/zsh' 'exit 17' > scripts/build-app.sh
touch scripts/embed-rime-runtime.sh
chmod +x scripts/{build-app,embed-rime-runtime}.sh
version=$(plutil -extract CFBundleShortVersionString raw Resources/ChineseInputMethod.plist)
pkg="SentenceAlong-${version}-macOS-arm64-unsigned.pkg"
print 'previous package contents' > ".build/dist/$pkg"
(cd .build/dist && /usr/bin/shasum -a 256 "$pkg" > "$pkg.sha256")
expect_failure 17 env CODE_SIGN_IDENTITY=- INSTALLER_SIGN_IDENTITY= NOTARYTOOL_PROFILE= scripts/build-installer.sh release
(cd .build/dist && /usr/bin/shasum -a 256 -c "$pkg.sha256")
echo "Build artifact checks passed"
