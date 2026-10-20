#!/usr/bin/env bash
set -euo pipefail
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
runtime_test="$TEST_DIR/mcp-worker-runtime.php"
temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT
command -v php >/dev/null || { echo 'PHP CLI is required for MCP worker tests.' >&2; exit 1; }

php "$runtime_test"
for disabled in pcntl_fork posix_setsid proc_open; do
    if php -d "disable_functions=$disabled" "$runtime_test" > "$temporary/output" 2>&1; then
        printf 'Disabled required worker function was accepted: %s\n' "$disabled" >&2
        exit 1
    fi
    grep -F "Missing MCP worker function: $disabled" "$temporary/output" >/dev/null
done
printf 'MCP worker runtime and missing-function rejection tests passed.\n'
