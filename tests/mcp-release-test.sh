#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DETECTOR="$REPO_ROOT/src/bin/check-mcp-release.sh"
# shellcheck source=../src/lib/mcp-package.sh
source "$REPO_ROOT/src/lib/mcp-package.sh"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TMP"' EXIT

fail() {
	printf 'not ok - %s\n' "$*" >&2
	exit 1
}

write_xml() {
	local version="${1:-1.0.1}" minimum="${2:-8.3.0}" platform="${3:-6\\.[1-9][0-9]*}" hash_character="${4:-a}"
	local checksum
	checksum="$(printf '%128s' '' | tr ' ' "$hash_character")"
	cat > "$TEST_TMP/update.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<updates><update>
  <name>Joomengine MCP</name><element>pkg_joomengine_mcp</element><type>package</type>
  <version>$version</version><tags><tag>stable</tag></tags>
  <downloads><downloadurl type="full" format="zip">https://example.test/mcp-$version.zip</downloadurl></downloads>
  <sha512>$checksum</sha512><php_minimum>$minimum</php_minimum>
  <targetplatform name="joomla" version="$platform" />
</update></updates>
EOF
}

reset_case() {
	cat > "$TEST_TMP/versions.json" <<'EOF'
{"5":{"joomla":"5.4.8","php":["8.3"],"variants":["apache"]},
 "6":{"joomla":"6.1.3","php":["8.3","8.4"],"variants":["apache","fpm"]}}
EOF
	write_xml
	local package
	package="$(mcp_resolve_package "$TEST_TMP/update.xml")"
	jq -c --argjson package "$package" '
		to_entries[] | .key as $major | .value | .joomla as $joomla |
		.php[] as $php | .variants[] as $variant |
		{
			version: ($major + ".1.0"), major: $major, joomla: $joomla, php: $php,
			variant: $variant, flavor: "standard", mcp: null, mcp_input_sha: "none",
			jcb_sha: ("a" * 128), release_input_sha: ("b" * 64),
			build_input_sha: ("c" * 64), base_index_digest: ("sha256:" + ("d" * 64)),
			base_platform_state_sha: ("e" * 64), platforms: ["linux/amd64","linux/arm64/v8"]
		} as $standard |
		$standard, ($standard | select(.major == "6") |
			.flavor = "mcp" | .mcp = $package | .mcp_input_sha = ("f" * 64))
	' "$TEST_TMP/versions.json" > "$TEST_TMP/manifest.ndjson"
	jq -r '[.version, .php, .joomla, .variant, .jcb_sha, .release_input_sha,
		.build_input_sha, .base_index_digest, .base_platform_state_sha,
		(.platforms | join(",")), .flavor, .mcp_input_sha] | join(" ")' \
		"$TEST_TMP/manifest.ndjson" > "$TEST_TMP/hashes.txt"
}

rewrite_manifest() {
	jq -c "$1" "$TEST_TMP/manifest.ndjson" > "$TEST_TMP/manifest.next"
	mv "$TEST_TMP/manifest.next" "$TEST_TMP/manifest.ndjson"
}

run_detector() {
	: > "$TEST_TMP/output"
	GITHUB_OUTPUT="$TEST_TMP/output" "$DETECTOR" \
		--xml-file "$TEST_TMP/update.xml" --versions-file "$TEST_TMP/versions.json" \
		--manifest-file "$TEST_TMP/manifest.ndjson" --hashes-file "$TEST_TMP/hashes.txt" \
		> "$TEST_TMP/log" 2>&1
}

assert_changed() {
	local expected="$1" message="$2" before after
	before="$(sha256sum "$TEST_TMP/versions.json" "$TEST_TMP/manifest.ndjson" "$TEST_TMP/hashes.txt")"
	if ! run_detector; then
		cat "$TEST_TMP/log" >&2
		fail "$message: detector failed"
	fi
	grep -Fxq "changed=$expected" "$TEST_TMP/output" || fail "$message: incorrect changed output"
	grep -Eq '^mcp_version=[0-9]+\.[0-9]+\.[0-9]+$' "$TEST_TMP/output" || fail "$message: missing version output"
	[[ "$(wc -l < "$TEST_TMP/output")" -eq 2 ]] || fail "$message: unexpected workflow output"
	after="$(sha256sum "$TEST_TMP/versions.json" "$TEST_TMP/manifest.ndjson" "$TEST_TMP/hashes.txt")"
	[[ "$before" == "$after" ]] || fail "$message: detector changed build state"
	printf 'ok - %s\n' "$message"
}

reset_case
assert_changed no 'published compatible MCP counterparts do not rebuild'

reset_case
rewrite_manifest 'select(.flavor != "mcp" or .php != "8.4" or .variant != "fpm")'
assert_changed yes 'one missing eligible counterpart requests publishing'

reset_case
write_xml 1.0.2
assert_changed yes 'new stable MCP version requests publishing'

reset_case
write_xml 1.0.1 8.3.0 '6\.[1-9][0-9]*' b
assert_changed yes 'changed checksum is detected even without a version bump'

reset_case
write_xml 1.0.1 8.5.0
assert_changed no 'higher PHP minimum incompatible with the entire matrix does not rebuild'

reset_case
write_xml 1.0.1 8.3.0 '7\.'
assert_changed no 'changed Joomla constraint incompatible with the entire matrix does not rebuild'

reset_case
awk '$11 != "mcp"' "$TEST_TMP/hashes.txt" > "$TEST_TMP/hashes.next"
mv "$TEST_TMP/hashes.next" "$TEST_TMP/hashes.txt"
assert_changed yes 'a generated manifest without successful MCP publishing is retried'

reset_case
sed 's/6\.1\.3/6.2.0/' "$TEST_TMP/versions.json" > "$TEST_TMP/versions.next"
mv "$TEST_TMP/versions.next" "$TEST_TMP/versions.json"
assert_changed yes 'current Joomla matrix requires fresh counterparts despite stale manifest contexts'

reset_case
jq -sc 'map(select(.major == "6" and .flavor == "standard"))[0] |
	.joomla = "6.0.0" | .php = "8.2" | .variant = "fpm-alpine"' \
	"$TEST_TMP/manifest.ndjson" > "$TEST_TMP/stale.ndjson"
cat "$TEST_TMP/stale.ndjson" >> "$TEST_TMP/manifest.ndjson"
assert_changed no 'obsolete Joomla and PHP contexts do not cause repeated publishing'

reset_case
rewrite_manifest 'if .flavor == "standard" then del(.flavor, .mcp, .mcp_input_sha) else . end'
assert_changed no 'legacy standard manifests remain compatible and unchanged'

reset_case
rewrite_manifest 'if .major == "6" then .version = "6.2.0-rc1" else . end'
sed 's/^6\.1\.0 /6.2.0-rc1 /' "$TEST_TMP/hashes.txt" > "$TEST_TMP/hashes.next"
mv "$TEST_TMP/hashes.next" "$TEST_TMP/hashes.txt"
assert_changed no 'published JCB prerelease counterparts use the same detector'

reset_case
: > "$TEST_TMP/manifest.ndjson"
: > "$TEST_TMP/hashes.txt"
assert_changed yes 'an empty manifest bootstraps compatible MCP images'

reset_case
printf '<updates><update>invalid XML\n' > "$TEST_TMP/update.xml"
if run_detector; then
	fail 'malformed update XML unexpectedly succeeded'
fi
[[ ! -s "$TEST_TMP/output" ]] || fail 'malformed XML emitted success outputs'
printf 'ok - malformed XML fails without workflow outputs\n'

reset_case
rm "$TEST_TMP/manifest.ndjson" "$TEST_TMP/hashes.txt"
run_detector || fail 'missing initial build state failed'
grep -Fxq 'changed=yes' "$TEST_TMP/output" || fail 'missing build state did not request publishing'
[[ ! -e "$TEST_TMP/manifest.ndjson" && ! -e "$TEST_TMP/hashes.txt" ]] || fail 'poll created build state'
printf 'ok - missing build state requests publishing without creating files\n'
