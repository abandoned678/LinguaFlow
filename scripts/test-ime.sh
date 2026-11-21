#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ ! -x .build/ime-testing/IMERunner ]]; then
  print -u2 "Build first with scripts/build-debug-ime.sh"
  exit 2
fi
exec "$PWD/.build/ime-testing/IMERunner" "$@"
