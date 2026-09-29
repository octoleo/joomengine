#!/usr/bin/env bash
# Shared MCP update-server resolution for the image generator and release poller.
# Sourcing this file does not fetch data or change the caller's shell options.

MCP_UPDATE_URL="${MCP_UPDATE_URL:-https://raw.githubusercontent.com/joomengine/mcp_package/refs/heads/main/.github/joomengine_mcp_update_server.xml}"

_mcp_error() {
	printf '[ERROR] MCP package: %s\n' "$*" >&2
	return 2
}

_mcp_version_normalize() {
	local version="${1:-}"
	if [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))?$ ]]; then
		printf '%s.%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[4]:-0}"
	else
		return 2
	fi
}

_mcp_version_at_least() {
	local actual="$1" minimum="$2" first
	first="$(printf '%s\n%s\n' "$actual" "$minimum" | LC_ALL=C sort -V | head -n 1)" || return 2
	[[ "$first" == "$minimum" ]]
}

_mcp_https_url_valid() {
	# Restrict values interpolated into Dockerfile/shell templates to safe ASCII.
	# Encoded path/query characters remain supported; credentials and fragments do not.
	local pattern='^https://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?(/[A-Za-z0-9._~:/?@%&=+,!-]*)?$'
	[[ "$1" =~ $pattern ]]
}

_mcp_platform_valid() {
	local pattern="$1" status=0
	[[ -n "$pattern" && "$pattern" != *$'\n'* && ! "$pattern" =~ [[:cntrl:]] ]] || return 2
	# Joomla prefixes targetplatform expressions with ^. Use PCRE rather than ERE,
	# preserving constructs such as \d and non-capturing groups used by Joomla XML.
	printf '\n' | LC_ALL=C grep -P -q -- "^(?:${pattern})" 2>/dev/null || status=$?
	[[ "$status" -le 1 ]] || return 2
}

_mcp_xml_single() {
	local xml_file="$1" path="$2" count value
	count="$(xmlstarlet sel -t -v "count($path)" "$xml_file")" || return 2
	[[ "$count" == 1 ]] || { _mcp_error "expected exactly one $path"; return 2; }
	value="$(xmlstarlet sel -t -v "normalize-space($path)" "$xml_file")" || return 2
	[[ -n "$value" ]] || { _mcp_error "empty $path"; return 2; }
	printf '%s\n' "$value"
}

# Print one canonical JSON object pinning the highest stable package release.
# The latest release is selected before its payload is validated: invalid latest
# metadata must fail instead of silently falling back to an older package.
mcp_resolve_package() (
	local xml_file="${1:-}" update_path count index path version stable
	local latest_version='' selected_index selected_path url sha512 php_minimum target_platform
	local package_json='' candidate_json input_sha
	local -a latest_indices=()
	[[ -f "$xml_file" ]] || { _mcp_error "update XML is not a file: $xml_file"; return 2; }
	# Do not permit remote or local entity expansion while reading update metadata.
	if LC_ALL=C grep -Eq '<![[:space:]]*(DOCTYPE|ENTITY)' "$xml_file"; then
		_mcp_error 'DTD and entity declarations are not permitted'
		return 2
	fi
	if ! xmlstarlet val --quiet "$xml_file"; then
		_mcp_error 'invalid update XML'
		return 2
	fi
	update_path="/updates/update[normalize-space(element)='pkg_joomengine_mcp' and normalize-space(type)='package']"
	count="$(xmlstarlet sel -t -v "count($update_path)" "$xml_file")" || return 2
	[[ "$count" =~ ^[0-9]+$ ]] || { _mcp_error 'invalid update record count'; return 2; }
	for ((index = 1; index <= count; index++)); do
		path="($update_path)[$index]"
		stable="$(xmlstarlet sel -t -v "count($path/tags/tag[translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz')='stable'])" "$xml_file")" || return 2
		[[ "$stable" != 0 ]] || continue
		version="$(_mcp_xml_single "$xml_file" "$path/version")" || return 2
		if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
			# A prerelease is never stable, even if its tag incorrectly says stable.
			if [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-[0-9A-Za-z.-]+(\+[0-9A-Za-z.-]+)?$ ]]; then
				continue
			fi
			_mcp_error "invalid stable version: $version"
			return 2
		fi
		if [[ -z "$latest_version" ]] || { [[ "$version" != "$latest_version" ]] && _mcp_version_at_least "$version" "$latest_version"; }; then
			latest_version="$version"
			latest_indices=("$index")
		elif [[ "$version" == "$latest_version" ]]; then
			latest_indices+=("$index")
		fi
	done
	[[ -n "$latest_version" ]] || { _mcp_error 'no stable pkg_joomengine_mcp package release'; return 2; }
	for selected_index in "${latest_indices[@]}"; do
		selected_path="($update_path)[$selected_index]"
		_mcp_xml_single "$xml_file" "$selected_path/element" >/dev/null || return 2
		_mcp_xml_single "$xml_file" "$selected_path/type" >/dev/null || return 2
		url="$(_mcp_xml_single "$xml_file" "$selected_path/downloads/downloadurl[@type='full' and @format='zip']")" || return 2
		sha512="$(_mcp_xml_single "$xml_file" "$selected_path/sha512")" || return 2
		php_minimum="$(_mcp_xml_single "$xml_file" "$selected_path/php_minimum")" || return 2
		target_platform="$(_mcp_xml_single "$xml_file" "$selected_path/targetplatform[@name='joomla']/@version")" || return 2
		_mcp_https_url_valid "$url" || { _mcp_error 'download URL must be safe HTTPS'; return 2; }
		[[ "$sha512" =~ ^[0-9A-Fa-f]{128}$ ]] || { _mcp_error 'SHA-512 must contain exactly 128 hexadecimal characters'; return 2; }
		php_minimum="$(_mcp_version_normalize "$php_minimum")" || { _mcp_error 'invalid PHP minimum'; return 2; }
		_mcp_platform_valid "$target_platform" || { _mcp_error 'invalid Joomla targetplatform expression'; return 2; }
		candidate_json="$(jq -cnS --arg version "$latest_version" --arg url "$url" \
			--arg sha512 "${sha512,,}" --arg php_minimum "$php_minimum" \
			--arg target_platform "$target_platform" \
			'{version: $version, url: $url, sha512: $sha512, php_minimum: $php_minimum, target_platform: $target_platform}')" || return 2
		if [[ -n "$package_json" && "$package_json" != "$candidate_json" ]]; then
			_mcp_error "conflicting records for latest stable release $latest_version"
			return 2
		fi
		package_json="$candidate_json"
	done
	input_sha="$(printf '%s\n' "$package_json" | sha256sum | awk '{ print $1 }')" || return 2
	jq -cS --arg input_sha "$input_sha" '. + {input_sha: $input_sha}' <<< "$package_json"
)

# Return 0 when compatible, 1 when incompatible, and 2 for invalid inputs.
# An unresolved PHP minor such as 8.3 is conservatively treated as 8.3.0.
mcp_package_supports() {
	local package_json="${1:-}" joomla_version="${2:-}" php_version="${3:-}"
	local php_minimum target_platform status=0
	php_minimum="$(jq -er '.php_minimum | select(type == "string" and length > 0)' <<< "$package_json")" || { _mcp_error 'missing PHP minimum in package metadata'; return 2; }
	target_platform="$(jq -er '.target_platform | select(type == "string" and length > 0)' <<< "$package_json")" || { _mcp_error 'missing targetplatform in package metadata'; return 2; }
	joomla_version="$(_mcp_version_normalize "$joomla_version")" || { _mcp_error 'invalid Joomla version'; return 2; }
	php_version="$(_mcp_version_normalize "$php_version")" || { _mcp_error 'invalid PHP version'; return 2; }
	php_minimum="$(_mcp_version_normalize "$php_minimum")" || { _mcp_error 'invalid PHP minimum'; return 2; }
	_mcp_platform_valid "$target_platform" || { _mcp_error 'invalid Joomla targetplatform expression'; return 2; }
	_mcp_version_at_least "$joomla_version" '6.0.0' || return 1
	_mcp_version_at_least "$php_version" "$php_minimum" || return 1
	printf '%s\n' "$joomla_version" | LC_ALL=C grep -P -q -- "^(?:${target_platform})" || status=$?
	[[ "$status" -le 1 ]] || { _mcp_error 'unable to match Joomla targetplatform'; return 2; }
	return "$status"
}

# Fetch once per build/poll invocation; deploys use the pinned archive in the image.
mcp_fetch_package() (
	local url="${1:-$MCP_UPDATE_URL}" xml_file
	_mcp_https_url_valid "$url" || { _mcp_error 'update URL must be safe HTTPS'; return 2; }
	xml_file="$(mktemp)" || return 2
	trap 'rm -f -- "$xml_file"' EXIT
	if ! curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
		--retry 3 --retry-delay 2 --retry-connrefused --connect-timeout 15 --max-time 60 \
		--output "$xml_file" "$url"; then
		_mcp_error "unable to fetch update XML: $url"
		return 2
	fi
	mcp_resolve_package "$xml_file"
)
