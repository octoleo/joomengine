#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TMP"' EXIT

# These tests exercise real XML and JSON parsing. Only the network is stubbed.
for dependency in xmlstarlet jq grep sort sha256sum; do
	command -v "$dependency" >/dev/null || { printf 'missing dependency: %s\n' "$dependency" >&2; exit 1; }
done
# shellcheck disable=SC1091
source "$REPO_ROOT/src/lib/mcp-package.sh"

fail() {
	printf 'not ok - %s\n' "$*" >&2
	exit 1
}

assert_status() {
	local expected="$1" actual=0
	shift
	"$@" > "$TEST_TMP/output" 2> "$TEST_TMP/error" || actual=$?
	[[ "$actual" == "$expected" ]] || {
		cat "$TEST_TMP/error" >&2
		fail "$* returned $actual, expected $expected"
	}
}

assert_json() {
	local json="$1" expression="$2"
	jq -e "$expression" <<< "$json" >/dev/null || fail "metadata does not satisfy $expression"
}

HASH_A="$(printf 'a%.0s' {1..128})"
HASH_B="$(printf 'b%.0s' {1..128})"

update() {
	local version="$1" tag="${2:-stable}" hash="${3-$HASH_A}"
	local php="${4:-8.3.0}" target="${5:-6\.[1-9][0-9]*}" url="${6:-https://example.test/mcp-$1.zip}"
	local element="${7:-pkg_joomengine_mcp}" type="${8:-package}"
	cat <<EOF
<update>
  <element>$element</element><type>$type</type><version>$version</version>
  <tags><tag>$tag</tag></tags>
  <downloads><downloadurl type="full" format="zip">$url</downloadurl></downloads>
  <sha512>$hash</sha512><php_minimum>$php</php_minimum>
  <targetplatform name="joomla" version="$target" />
</update>
EOF
}

fixture() {
	{ printf '<updates>\n'; cat; printf '</updates>\n'; } > "$TEST_TMP/updates.xml"
}

{
	update 1.10.0
	update 3.0.0-rc1 stable
	update 1.9.0
	update 7.0.0 beta
	update 99.0.0 stable "$HASH_A" 8.3.0 '6.*' 'https://example.test/other.zip' other_extension
} | fixture
resolved="$(mcp_resolve_package "$TEST_TMP/updates.xml")"
assert_json "$resolved" '.version == "1.10.0" and .php_minimum == "8.3.0" and .target_platform == "6\\.[1-9][0-9]*"'
assert_json "$resolved" '.input_sha | test("^[0-9a-f]{64}$")'

# Reordering update records does not change the pin or its input fingerprint.
{ update 1.9.0; update 1.10.0; } | fixture
reordered="$(mcp_resolve_package "$TEST_TMP/updates.xml")"
[[ "$reordered" == "$resolved" ]] || fail 'XML order changed selected package'
printf 'ok - highest stable numeric version wins independently of XML order\n'

assert_status 0 mcp_package_supports "$resolved" 6.1.3 8.3
assert_status 0 mcp_package_supports "$resolved" 6.2.0 8.4.1
assert_status 0 mcp_package_supports "$resolved" 6.10.0 8.10
assert_status 1 mcp_package_supports "$resolved" 6.0.99 8.4
assert_status 1 mcp_package_supports "$resolved" 5.4.9 8.4
assert_status 1 mcp_package_supports "$resolved" 7.1.0 8.4
assert_status 1 mcp_package_supports "$resolved" 6.1.3 8.2.99
assert_status 2 mcp_package_supports "$resolved" 6.x 8.4
assert_status 2 mcp_package_supports "$resolved" 6.1.3 8.x
assert_status 2 mcp_package_supports '{}' 6.1.3 8.4
assert_status 2 mcp_package_supports '{"php_minimum":"8.3.0","target_platform":"["}' 6.1.3 8.4
printf 'ok - Joomla platform and PHP minimum gate eligible image variants\n'

update 1.10.0 stable "$HASH_A" 8.3.2 '6\.\d+' | fixture
patched="$(mcp_resolve_package "$TEST_TMP/updates.xml")"
assert_status 1 mcp_package_supports "$patched" 6.1.3 8.3
assert_status 1 mcp_package_supports "$patched" 6.1.3 8.3.1
assert_status 0 mcp_package_supports "$patched" 6.1.3 8.3.2
assert_status 0 mcp_package_supports "$patched" 6.10.1 8.4
[[ "$(jq -r .input_sha <<< "$patched")" != "$(jq -r .input_sha <<< "$resolved")" ]] || fail 'compatibility change did not update fingerprint'
update 1.10.0 stable "$HASH_A" 8.3.0 '6\.\d+' | fixture
platform_changed="$(mcp_resolve_package "$TEST_TMP/updates.xml")"
[[ "$(jq -r .input_sha <<< "$platform_changed")" != "$(jq -r .input_sha <<< "$resolved")" ]] || fail 'targetplatform change did not update fingerprint'
update 1.10.0 stable "$HASH_A" 8.3.2 | fixture
php_changed="$(mcp_resolve_package "$TEST_TMP/updates.xml")"
[[ "$(jq -r .input_sha <<< "$php_changed")" != "$(jq -r .input_sha <<< "$resolved")" ]] || fail 'PHP minimum change did not update fingerprint'
printf 'ok - patch minima, PCRE expressions, and compatibility fingerprints are enforced\n'

{ update 1.0.0; update 1.0.0; } | fixture
assert_status 0 mcp_resolve_package "$TEST_TMP/updates.xml"
{ update 1.0.0; update 1.0.0 stable "$HASH_B"; } | fixture
assert_status 2 mcp_resolve_package "$TEST_TMP/updates.xml"
{ update 1.0.0; update 1.0.0 stable "$HASH_A" 8.4.0; } | fixture
assert_status 2 mcp_resolve_package "$TEST_TMP/updates.xml"
printf 'ok - identical latest duplicates are accepted and conflicting metadata fails\n'

{ update 1.0.0; update 1.1.0 stable ''; } | fixture
assert_status 2 mcp_resolve_package "$TEST_TMP/updates.xml"
update 1.0.0 stable 'not-a-sha512' | fixture
assert_status 2 mcp_resolve_package "$TEST_TMP/updates.xml"
update 1.0.0 stable "$HASH_A" 8.3.0 '[' | fixture
assert_status 2 mcp_resolve_package "$TEST_TMP/updates.xml"
# This literal shell expansion is intentionally an invalid metadata value.
# shellcheck disable=SC2016
update 1.0.0 stable "$HASH_A" 8.3.0 '6.*' 'https://example.test/$(touch-pwned).zip' | fixture
assert_status 2 mcp_resolve_package "$TEST_TMP/updates.xml"
update 1.0.0 stable "$HASH_A" 8.3.0 '6.*' 'http://example.test/insecure.zip' | fixture
assert_status 2 mcp_resolve_package "$TEST_TMP/updates.xml"
update 1.0.0 stable "$HASH_A" invalid | fixture
assert_status 2 mcp_resolve_package "$TEST_TMP/updates.xml"
printf '<updates><update>\n' > "$TEST_TMP/updates.xml"
assert_status 2 mcp_resolve_package "$TEST_TMP/updates.xml"
printf '<!DOCTYPE updates [<!ENTITY metadata "ignored">]><updates/>\n' > "$TEST_TMP/updates.xml"
assert_status 2 mcp_resolve_package "$TEST_TMP/updates.xml"
printf '\377\376<\000!\000D\000O\000C\000T\000Y\000P\000E\000' > "$TEST_TMP/updates.xml"
assert_status 2 mcp_resolve_package "$TEST_TMP/updates.xml"
update 2.0.0-rc1 stable | fixture
assert_status 2 mcp_resolve_package "$TEST_TMP/updates.xml"
update 2.0.0 beta | fixture
assert_status 2 mcp_resolve_package "$TEST_TMP/updates.xml"
update 1.0.0 stable "$HASH_A" 8.3.0 '6.*' 'https://example.test/plugin.zip' pkg_joomengine_mcp plugin | fixture
assert_status 2 mcp_resolve_package "$TEST_TMP/updates.xml"
printf 'ok - invalid latest metadata, unsafe URLs, malformed XML, and absent stable packages fail closed\n'

# The Joomla >= 6 floor remains enforced even if an XML pattern permits 5.x.
update 1.0.0 stable "$HASH_A" 8.3.0 '(5|6|7)\.' | fixture
future="$(mcp_resolve_package "$TEST_TMP/updates.xml")"
assert_status 1 mcp_package_supports "$future" 5.4.0 8.3
assert_status 0 mcp_package_supports "$future" 7.0.0 8.3
printf 'ok - future Joomla eligibility follows metadata above the Joomla 6 floor\n'

# Stub only curl, and verify that both success and failure clean the fetched XML.
update 1.0.0 | fixture
mkdir "$TEST_TMP/downloads"
curl() {
	local output='' secure=no redirects_secure=no
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--output) output="$2"; shift 2 ;;
			--proto) [[ "$2" == '=https' ]] && secure=yes; shift 2 ;;
			--proto-redir) [[ "$2" == '=https' ]] && redirects_secure=yes; shift 2 ;;
			*) shift ;;
		esac
	done
	[[ "$secure" == yes && "$redirects_secure" == yes && -n "$output" ]] || return 99
	printf '%s\n' "$output" > "$TEST_TMP/download-path"
	[[ "${FAIL_FETCH:-no}" != yes ]] || return 22
	cp "$TEST_TMP/updates.xml" "$output"
}
TMPDIR="$TEST_TMP/downloads" assert_status 0 mcp_fetch_package 'https://example.test/updates.xml'
[[ ! -e "$(< "$TEST_TMP/download-path")" ]] || fail 'successful fetch leaked temporary XML'
assert_json "$(< "$TEST_TMP/output")" '.version == "1.0.0"'
FAIL_FETCH=yes TMPDIR="$TEST_TMP/downloads" assert_status 2 mcp_fetch_package 'https://example.test/updates.xml'
[[ ! -e "$(< "$TEST_TMP/download-path")" ]] || fail 'failed fetch leaked temporary XML'
assert_status 2 mcp_fetch_package 'http://example.test/updates.xml'
printf 'ok - fetch resolves metadata, enforces HTTPS redirects, and cleans temporary files\n'
