#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$TEST_DIR/image-config-test.sh"
"$TEST_DIR/build-targets-test.sh"
"$TEST_DIR/mcp-package-test.sh"
"$TEST_DIR/build-engine-test.sh"
"$TEST_DIR/publish-aliases-test.sh"
"$TEST_DIR/recover-defaults-test.sh"
"$TEST_DIR/release-detector/test-release-detector.sh"
"$TEST_DIR/mcp-release-test.sh"
