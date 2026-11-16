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
	write_hashes
}

write_hashes() {
	jq -r '. as $record |
		([.version, .php, .joomla, .variant, .jcb_sha, .release_input_sha,
			.build_input_sha, .base_index_digest, .base_platform_state_sha,
			(.platforms | join(",")), .flavor, .mcp_input_sha] +
			(if ($record | has("profile")) or ($record | has("target")) then [$record.profile // "standard"] else [] end) +
			(if $record | has("target") then [$record.target] else [] end)) | join(" ")' \
		"$TEST_TMP/manifest.ndjson" > "$TEST_TMP/hashes.txt"
}

rewrite_manifest() {
	jq -c "$1" "$TEST_TMP/manifest.ndjson" > "$TEST_TMP/manifest.next"
	mv "$TEST_TMP/manifest.next" "$TEST_TMP/manifest.ndjson"
}

enable_dev_profiles() {
	jq '."6".profiles = ["standard", "dev"]' "$TEST_TMP/versions.json" > "$TEST_TMP/versions.next"
	mv "$TEST_TMP/versions.next" "$TEST_TMP/versions.json"
	rewrite_manifest '.profile = "standard" | ., (select(.major == "6") | .profile = "dev")'
	write_hashes
}

reset_named_targets() {
	reset_case
	write_xml 1.0.1 8.3.0 '(6|7)\.'
	local package
	package="$(mcp_resolve_package "$TEST_TMP/update.xml")"
	jq '{
		"stable6": (."6" + {jcb:{major:"6",versions:"latest-stable"}}),
		"preview7": (."6" + {
			joomla:"7.0.0-alpha1",channel:"alpha",update:"pinned",tags:"qualified",
			jcb:{major:"6",versions:"latest-alpha"}
		})
	}' "$TEST_TMP/versions.json" > "$TEST_TMP/versions.next"
	mv "$TEST_TMP/versions.next" "$TEST_TMP/versions.json"
	jq -c --argjson package "$package" '
		select(.major == "6") | .profile = "standard" |
		if .flavor == "mcp" then .mcp = $package else . end |
		(. + {target:"stable6",joomla_channel:"stable",tag_policy:"default"}),
		(. + {target:"preview7",joomla:"7.0.0-alpha1",joomla_channel:"alpha",tag_policy:"qualified",version:"6.2.1-alpha2"})
	' "$TEST_TMP/manifest.ndjson" > "$TEST_TMP/manifest.next"
	mv "$TEST_TMP/manifest.next" "$TEST_TMP/manifest.ndjson"
	write_hashes
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
enable_dev_profiles
assert_changed no 'published standard and dev MCP counterparts are checked independently'

reset_case
enable_dev_profiles
rewrite_manifest 'select(.flavor != "mcp" or .profile != "dev" or .php != "8.4" or .variant != "fpm")'
assert_changed yes 'a missing dev MCP counterpart requests publishing'

reset_case
enable_dev_profiles
awk '$13 != "dev"' "$TEST_TMP/hashes.txt" > "$TEST_TMP/hashes.next"
mv "$TEST_TMP/hashes.next" "$TEST_TMP/hashes.txt"
assert_changed yes 'dev manifest rows without published dev fingerprints request publishing'

reset_case
enable_dev_profiles
rewrite_manifest 'if .flavor == "mcp" and .profile == "dev" then .mcp.version = "0.9.0" else . end'
assert_changed yes 'stale dev package metadata is not hidden by current standard images'

reset_case
enable_dev_profiles
jq '."6".profiles = ["standard"]' "$TEST_TMP/versions.json" > "$TEST_TMP/versions.next"
mv "$TEST_TMP/versions.next" "$TEST_TMP/versions.json"
rewrite_manifest 'if .flavor == "mcp" and .profile == "dev" then .mcp.version = "0.9.0" else . end'
assert_changed no 'removed profiles do not trigger repeated publishing from obsolete manifest rows'

reset_named_targets
assert_changed no 'named Joomla targets can share a JCB major without duplicate MCP matches'

reset_named_targets
rewrite_manifest 'select(.flavor != "mcp" or .target != "preview7")'
assert_changed yes 'a configured preview target requires its own MCP counterparts'

reset_named_targets
awk '$14 != "preview7"' "$TEST_TMP/hashes.txt" > "$TEST_TMP/hashes.next"
mv "$TEST_TMP/hashes.next" "$TEST_TMP/hashes.txt"
assert_changed yes 'target-specific manifests require target-specific published fingerprints'

reset_named_targets
jq '.preview7 |= (.joomla = "6.1.3" | .channel = "stable" | .jcb.versions = "latest-stable")' \
	"$TEST_TMP/versions.json" > "$TEST_TMP/versions.next"
mv "$TEST_TMP/versions.next" "$TEST_TMP/versions.json"
rewrite_manifest 'if .target == "preview7" then .joomla = "6.1.3" | .version = "6.1.0" | .joomla_channel = "stable" else . end'
write_hashes
assert_changed no 'distinct targets with identical Joomla and JCB versions remain independent'
rewrite_manifest 'select(.flavor != "mcp" or .target != "preview7")'
assert_changed yes 'another target cannot satisfy an otherwise identical missing MCP image'

reset_named_targets
jq '.preview7.enabled = false' "$TEST_TMP/versions.json" > "$TEST_TMP/versions.next"
mv "$TEST_TMP/versions.next" "$TEST_TMP/versions.json"
rewrite_manifest 'select(.flavor != "mcp" or .target != "preview7")'
assert_changed no 'disabled targets do not request MCP publication'

reset_named_targets
rewrite_manifest '., (select(.target == "preview7" and .flavor == "standard") | .version = "6.2.1-alpha1")'
assert_changed no 'latest-alpha excludes older JCB alpha releases from its expected matrix'

reset_named_targets
rewrite_manifest '., (select(.target == "preview7" and .flavor == "standard") | .version = "6.2.1-alpha10")'
assert_changed yes 'latest-alpha selects prerelease numbers numerically'

reset_named_targets
rewrite_manifest 'if .target == "preview7" then .version = "6.2.1-alpha" else . end'
write_hashes
rewrite_manifest '., (select(.target == "preview7" and .flavor == "standard") | .version = "6.2.1-alpha99")'
assert_changed no 'unnumbered JCB prereleases retain their established channel leadership'

reset_named_targets
jq '.preview7.jcb.versions = ["6.2.1-alpha2"]' "$TEST_TMP/versions.json" > "$TEST_TMP/versions.next"
mv "$TEST_TMP/versions.next" "$TEST_TMP/versions.json"
rewrite_manifest '., (select(.target == "preview7" and .flavor == "standard") | .version = "6.2.1-alpha10")'
assert_changed no 'explicit JCB selections ignore unselected releases'
jq '.preview7.jcb.versions = ["6.2.1-alpha3"]' "$TEST_TMP/versions.json" > "$TEST_TMP/versions.next"
mv "$TEST_TMP/versions.next" "$TEST_TMP/versions.json"
assert_changed yes 'an explicitly selected unpublished JCB release requests a build'

reset_named_targets
jq '.preview7.jcb.versions = "latest-rc"' "$TEST_TMP/versions.json" > "$TEST_TMP/versions.next"
mv "$TEST_TMP/versions.next" "$TEST_TMP/versions.json"
assert_changed yes 'a channel with no known release requests validation by the builder'

reset_named_targets
write_xml
assert_changed yes 'current package metadata changes still update eligible stable targets'
rewrite_manifest 'if .target == "stable6" and .flavor == "mcp" then .mcp.target_platform = "6\\.[1-9][0-9]*" else . end'
# Recompute exact resolved metadata: XML constraints are part of its fingerprint.
package="$(mcp_resolve_package "$TEST_TMP/update.xml")"
jq -c --argjson package "$package" 'if .target == "stable6" and .flavor == "mcp" then .mcp = $package else . end' \
	"$TEST_TMP/manifest.ndjson" > "$TEST_TMP/manifest.next"
mv "$TEST_TMP/manifest.next" "$TEST_TMP/manifest.ndjson"
write_hashes
assert_changed no 'Joomla 6-only MCP metadata does not enable a Joomla 7 preview target'

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

reset_case
jq '."6".profiles = ["unknown"]' "$TEST_TMP/versions.json" > "$TEST_TMP/versions.next"
mv "$TEST_TMP/versions.next" "$TEST_TMP/versions.json"
if run_detector; then
	fail 'unknown profile unexpectedly succeeded'
fi
[[ ! -s "$TEST_TMP/output" ]] || fail 'unknown profile emitted success outputs'
printf 'ok - unknown matrix profiles fail before package resolution\n'

# Verify the detector passes the JSON source URL to the shared fetcher.
reset_case
mkdir "$TEST_TMP/mock-bin"
cat > "$TEST_TMP/mock-bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=''
url=''
while [[ $# -gt 0 ]]; do
	case "$1" in
		--output) output="$2"; shift 2 ;;
		https://*) url="$1"; shift ;;
		*) shift ;;
	esac
done
[[ -n "$output" && -n "$url" ]]
printf '%s\n' "$url" > "$MCP_TEST_REQUESTED_URL"
cp "$MCP_TEST_XML" "$output"
EOF
chmod +x "$TEST_TMP/mock-bin/curl"
jq '.sources.mcp_updates_url = "https://example.test/configured-mcp.xml"' \
	"$REPO_ROOT/conf/build.json" > "$TEST_TMP/build.json"
: > "$TEST_TMP/output"
if ! env -u MCP_UPDATE_URL PATH="$TEST_TMP/mock-bin:$PATH" \
	MCP_TEST_REQUESTED_URL="$TEST_TMP/requested-url" MCP_TEST_XML="$TEST_TMP/update.xml" \
	GITHUB_OUTPUT="$TEST_TMP/output" "$DETECTOR" --config-file "$TEST_TMP/build.json" \
	--versions-file "$TEST_TMP/versions.json" --manifest-file "$TEST_TMP/manifest.ndjson" \
	--hashes-file "$TEST_TMP/hashes.txt" > "$TEST_TMP/log" 2>&1; then
	cat "$TEST_TMP/log" >&2
	fail 'JSON-configured MCP source failed'
fi
[[ "$(< "$TEST_TMP/requested-url")" == 'https://example.test/configured-mcp.xml' ]] || \
	fail 'detector ignored the JSON source URL'
grep -Fxq 'changed=no' "$TEST_TMP/output" || fail 'configured source caused an unnecessary rebuild'
printf 'ok - MCP detector fetches its source from the selected JSON configuration\n'
