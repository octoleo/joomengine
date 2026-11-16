#!/usr/bin/env bash
set -euo pipefail

# Compare the latest stable MCP package with the published image manifest.
# This detector never advances the manifest or any other build state.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/mcp-package.sh
source "$SCRIPT_DIR/../lib/mcp-package.sh"
# shellcheck source=../lib/build-targets.sh
source "$SCRIPT_DIR/../lib/build-targets.sh"

VERSIONS_FILE="$REPO_ROOT/conf/versions.json"
BUILD_CONFIG_FILE="$REPO_ROOT/conf/build.json"
MANIFEST_FILE="$REPO_ROOT/conf/manifest.ndjson"
HASHES_FILE="$REPO_ROOT/conf/hashes.txt"
XML_FILE=""

fail() {
	printf '[ERROR] %s\n' "$*" >&2
	exit 1
}

show_help() {
	cat <<'EOF'
Usage: check-mcp-release.sh [options]

  --xml-file PATH       Read MCP update metadata locally instead of downloading it
  --config-file PATH    Read image profiles and package sources from JSON
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
		--xml-file|--config-file|--versions-file|--manifest-file|--hashes-file)
			[[ $# -ge 2 && -n "$2" ]] || fail "$1 requires a path"
			case "$1" in
				--xml-file) XML_FILE="$2" ;;
				--config-file) BUILD_CONFIG_FILE="$2" ;;
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
[[ -f "$BUILD_CONFIG_FILE" && -r "$BUILD_CONFIG_FILE" ]] || fail "Cannot read image configuration: $BUILD_CONFIG_FILE"
if ! jq -e '.profiles | type == "object" and length > 0' "$BUILD_CONFIG_FILE" >/dev/null; then
	fail "Invalid image profiles: $BUILD_CONFIG_FILE"
fi
if ! TARGETS_JSON="$(build_targets_normalize "$VERSIONS_FILE" "$BUILD_CONFIG_FILE")"; then
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
		(.joomla | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+(-(alpha|beta|rc)[0-9]*)?$")) and
		((.target // .major) | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_-]*$")) and
		(.php | type == "string" and test("^[0-9]+\\.[0-9]+$")) and
		((.profile // "standard") | type == "string" and test("^[a-z0-9][a-z0-9._-]*$")) and
		(.variant | type == "string" and test("^[a-z0-9][a-z0-9._-]*$")))
' "$MANIFEST_READ_FILE" >/dev/null; then
	fail "Invalid image manifest: $MANIFEST_FILE"
fi

if [[ -n "$XML_FILE" ]]; then
	PACKAGE="$(mcp_resolve_package "$XML_FILE")" || fail "Cannot resolve MCP package metadata"
else
	UPDATE_URL="$(mcp_update_url "$BUILD_CONFIG_FILE")" || fail "Cannot resolve MCP update URL"
	PACKAGE="$(mcp_fetch_package "$UPDATE_URL")" || fail "Cannot fetch MCP package metadata"
fi
MCP_VERSION="$(jq -er '.version | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' <<< "$PACKAGE")" || \
	fail "Invalid resolved MCP package version"

CHANGED="no"
ELIGIBLE="no"
while IFS=$'\t' read -r target major joomla php selector; do
	if mcp_package_supports "$PACKAGE" "$joomla" "$php"; then
		ELIGIBLE="yes"
	else
		status=$?
		[[ "$status" -eq 1 ]] || fail "Invalid MCP compatibility metadata"
		continue
	fi

	# Known JCB releases can be shared across Joomla targets. Apply this target's
	# selector before checking its own package builds; other targets cannot satisfy
	# a missing counterpart or force obsolete releases back into a narrowed matrix.
	releases="$(jq -sr --arg major "$major" --argjson selector "$selector" '
		def version_key:
			capture("^(?<major>[0-9]+)\\.(?<minor>[0-9]+)\\.(?<patch>[0-9]+)(-(?<channel>alpha|beta|rc)(?<number>[0-9]*))?$") |
			[(.major | tonumber), (.minor | tonumber), (.patch | tonumber),
				(if (.number // "") == "" then 999999 else (.number | tonumber) end)];
		[.[] | select((.flavor // "standard") == "standard" and .major == $major) | .version] |
		unique |
		if ($selector | type) == "array" then $selector
		elif $selector == "all" then .
		elif $selector == "latest-stable" then
			map(select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))) | sort_by(version_key) | .[-1:]
		else
			($selector | sub("^latest-"; "")) as $channel |
			map(select(test("-" + $channel + "[0-9]*$"))) | sort_by(version_key) | .[-1:]
		end | .[]
	' "$MANIFEST_READ_FILE")"
	if [[ -z "$releases" ]]; then
		CHANGED="yes"
		continue
	fi
	while IFS= read -r version; do
		while IFS=$'\t' read -r variant profile; do
			if ! expected_hash="$(jq -ser --arg version "$version" --arg joomla "$joomla" --arg php "$php" \
				--arg target "$target" --arg variant "$variant" --arg profile "$profile" --argjson package "$PACKAGE" '
				[.[] | select(.flavor == "mcp" and .version == $version and
					.joomla == $joomla and .php == $php and .variant == $variant and
					(.profile // "standard") == $profile and (.target // .major) == $target)] |
				select(length == 1 and .[0].mcp == $package) | .[0] |
				select(.mcp_input_sha | type == "string" and test("^[a-f0-9]{64}$")) |
				. as $record |
				([.version, .php, .joomla, .variant, .jcb_sha, .release_input_sha,
					.build_input_sha, .base_index_digest, .base_platform_state_sha,
					(.platforms | join(",")), .flavor, .mcp_input_sha] +
					(if ($record | has("profile")) or ($record | has("target")) then [$record.profile // "standard"] else [] end) +
					(if $record | has("target") then [$record.target] else [] end)) |
				select(all(.[]; type == "string" and length > 0)) | join(" ")
			' "$MANIFEST_READ_FILE")"; then
				CHANGED="yes"
			elif ! grep -Fxq -- "$expected_hash" "$HASHES_READ_FILE"; then
				# The generator can write a manifest before publishing. Only the
				# successful-build ledger proves that its image actually shipped.
				CHANGED="yes"
			fi
		done < <(jq -r --arg target "$target" '.[$target] |
			(.profiles // ["standard"])[] as $profile |
			.variants[] | [., $profile] | @tsv' <<< "$TARGETS_JSON")
	done <<< "$releases"
done < <(jq -r 'to_entries[] | .key as $target | .value | .joomla as $joomla |
	.jcb.major as $major | (.jcb.versions | tojson) as $selector |
	.php[] | [$target, $major, $joomla, ., $selector] | @tsv' <<< "$TARGETS_JSON")

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	printf 'changed=%s\nmcp_version=%s\n' "$CHANGED" "$MCP_VERSION" >> "$GITHUB_OUTPUT"
fi
printf 'MCP %s: changed=%s, compatible matrix=%s\n' "$MCP_VERSION" "$CHANGED" "$ELIGIBLE"
