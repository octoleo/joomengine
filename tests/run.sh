#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$TEST_DIR/docker-entrypoint-test.sh"
"$TEST_DIR/build-engine-test.sh"
"$TEST_DIR/release-detector/test-release-detector.sh"
