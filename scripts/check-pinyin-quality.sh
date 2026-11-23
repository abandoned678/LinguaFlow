#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/sentencealong-quality.XXXXXXXX")
trap '/bin/rm -rf "$scratch"' EXIT
./scripts/prepare-rime-data.sh "$scratch/shared" >/dev/null
if [[ ${1:-} == --baseline ]]; then
  # Identical engine and profile; vary only the bundled technical vocabulary.
  cp Vendor/rime-luna-pinyin/luna_pinyin.dict.yaml "$scratch/shared/"
elif [[ $# -gt 0 ]]; then
  print -u2 "usage: $0 [--baseline]"
  exit 64
fi
swift run rime-checks --quality "$scratch/shared" "$scratch/user" Tests/Fixtures/pinyin-quality.tsv
