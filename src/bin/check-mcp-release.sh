#!/usr/bin/env bash
set -euo pipefail

# Compare the latest stable MCP package with the published image manifest.
# This detector never advances the manifest or any other build state.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/mcp-package.sh
source "$SCRIPT_DIR/../lib/mcp-package.sh"

VERSIONS_FILE="$REPO_ROOT/conf/versions.json"
MANIFEST_FILE="$REPO_ROOT/conf/manifest.ndjson"
HASHES_FILE="$REPO_ROOT/conf/hashes.txt"
XML_FILE=""
MCP_UPDATE_URL="${MCP_UPDATE_URL:-https://raw.githubusercontent.com/joomengine/mcp_package/refs/heads/main/.github/joomengine_mcp_update_server.xml}"

fail() {
	printf '[ERROR] %s\n' "$*" >&2
	exit 1
}

show_help() {
	cat <<'EOF'
Usage: check-mcp-release.sh [options]

  --xml-file PATH       Read MCP update metadata locally instead of downloading it
  --versions-file PATH Read the configured Joomla/PHP/image-variant matrix
  --manifest-file PATH Read generated image metadata
  --hashes-file PATH   Read successfully published build fingerprints
  -h, --help           Show this help

Emits changed=yes|no and mcp_version to GITHUB_OUTPUT when it is set. A missing
manifest triggers the initial build when the package supports the build matrix.
The command does not modify versions, manifests, or successful build state.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--xml-file|--versions-file|--manifest-file|--hashes-file)
			[[ $# -ge 2 && -n "$2" ]] || fail "$1 requires a path"
			case "$1" in
				--xml-file) XML_FILE="$2" ;;
				--versions-file) VERSIONS_FILE="$2" ;;
				--manifest-file) MANIFEST_FILE="$2" ;;
				--hashes-file) HASHES_FILE="$2" ;;
			esac
			shift 2
			;;
		-h|--help) show_help; exit 0 ;;
		*) fail "Unknown option: $1" ;;
	esac
done

for command_name in jq grep; do
	command -v "$command_name" >/dev/null 2>&1 || fail "Missing required command: $command_name"
done
[[ -f "$VERSIONS_FILE" && -r "$VERSIONS_FILE" ]] || fail "Cannot read versions file: $VERSIONS_FILE"
if ! jq -e '
	type == "object" and length > 0 and
	all(to_entries[];
		.key as $major |
		($major | test("^[0-9]+$")) and
		(.value | type == "object") and
		(.value.joomla | type == "string" and test("^" + $major + "\\.[0-9]+\\.[0-9]+$")) and
		(.value.php | type == "array" and length > 0 and
			all(.[]; type == "string" and test("^[0-9]+\\.[0-9]+$"))) and
		(.value.variants | type == "array" and length > 0 and
			all(.[]; type == "string" and test("^[a-z0-9][a-z0-9._-]*$"))))
' "$VERSIONS_FILE" >/dev/null; then
	fail "Invalid Joomla build matrix: $VERSIONS_FILE"
fi

HASHES_READ_FILE="/dev/null"
if [[ -e "$HASHES_FILE" ]]; then
	[[ -f "$HASHES_FILE" && -r "$HASHES_FILE" ]] || fail "Cannot read successful build hashes: $HASHES_FILE"
	HASHES_READ_FILE="$HASHES_FILE"
fi

MANIFEST_READ_FILE="/dev/null"
if [[ -e "$MANIFEST_FILE" ]]; then
	[[ -f "$MANIFEST_FILE" && -r "$MANIFEST_FILE" ]] || fail "Cannot read manifest: $MANIFEST_FILE"
	MANIFEST_READ_FILE="$MANIFEST_FILE"
fi
if ! jq -se '
	all(.[];
		type == "object" and
		((.flavor // "standard") == "standard" or .flavor == "mcp") and
		(.version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+(-(alpha|beta|rc)[0-9]*)?$")) and
		(.major | type == "string" and test("^[0-9]+$")) and
		(.joomla | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
		(.php | type == "string" and test("^[0-9]+\\.[0-9]+$")) and
		(.variant | type == "string" and test("^[a-z0-9][a-z0-9._-]*$")))
' "$MANIFEST_READ_FILE" >/dev/null; then
	fail "Invalid image manifest: $MANIFEST_FILE"
fi

if [[ -n "$XML_FILE" ]]; then
	PACKAGE="$(mcp_resolve_package "$XML_FILE")" || fail "Cannot resolve MCP package metadata"
else
	PACKAGE="$(mcp_fetch_package "$MCP_UPDATE_URL")" || fail "Cannot fetch MCP package metadata"
fi
MCP_VERSION="$(jq -er '.version | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' <<< "$PACKAGE")" || \
	fail "Invalid resolved MCP package version"

CHANGED="no"
ELIGIBLE="no"
while IFS=$'\t' read -r major joomla php; do
	if mcp_package_supports "$PACKAGE" "$joomla" "$php"; then
		ELIGIBLE="yes"
	else
		status=$?
		[[ "$status" -eq 1 ]] || fail "Invalid MCP compatibility metadata"
		continue
	fi

	# Standard rows identify known JCB releases. Expand them against the CURRENT
	# matrix so obsolete Joomla versions or removed PHP variants cannot keep
	# requesting builds. Missing majors also need their first MCP build.
	releases="$(jq -sr --arg major "$major" '
		[.[] | select((.flavor // "standard") == "standard" and .major == $major) | .version] |
		unique | .[]
	' "$MANIFEST_READ_FILE")"
	if [[ -z "$releases" ]]; then
		CHANGED="yes"
		continue
	fi
	while IFS= read -r version; do
		while IFS= read -r variant; do
			if ! expected_hash="$(jq -ser --arg version "$version" --arg joomla "$joomla" --arg php "$php" \
				--arg variant "$variant" --argjson package "$PACKAGE" '
				[.[] | select(.flavor == "mcp" and .version == $version and
					.joomla == $joomla and .php == $php and .variant == $variant)] |
				select(length == 1 and .[0].mcp == $package) | .[0] |
				select(.mcp_input_sha | type == "string" and test("^[a-f0-9]{64}$")) |
				[.version, .php, .joomla, .variant, .jcb_sha, .release_input_sha,
					.build_input_sha, .base_index_digest, .base_platform_state_sha,
					(.platforms | join(",")), .flavor, .mcp_input_sha] |
				select(all(.[]; type == "string" and length > 0)) | join(" ")
			' "$MANIFEST_READ_FILE")"; then
				CHANGED="yes"
			elif ! grep -Fxq -- "$expected_hash" "$HASHES_READ_FILE"; then
				# The generator can write a manifest before publishing. Only the
				# successful-build ledger proves that its image actually shipped.
				CHANGED="yes"
			fi
		done < <(jq -r --arg major "$major" '.[$major].variants[]' "$VERSIONS_FILE")
	done <<< "$releases"
done < <(jq -r 'to_entries[] | .key as $major | .value | .joomla as $joomla |
	.php[] | [$major, $joomla, .] | @tsv' "$VERSIONS_FILE")

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	printf 'changed=%s\nmcp_version=%s\n' "$CHANGED" "$MCP_VERSION" >> "$GITHUB_OUTPUT"
fi
printf 'MCP %s: changed=%s, compatible matrix=%s\n' "$MCP_VERSION" "$CHANGED" "$ELIGIBLE"
