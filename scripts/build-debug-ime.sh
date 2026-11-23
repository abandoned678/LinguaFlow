#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
./scripts/build-app.sh debug
exec ./scripts/build-ime-test-tools.sh
