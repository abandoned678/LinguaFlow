#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export SENTENCEALONG_TEST_BUILD=1
./scripts/build-app.sh debug
exec ./scripts/build-ime-test-tools.sh
