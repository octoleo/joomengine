#!/usr/bin/env bash
# JSON-driven image configuration and deterministic Dockerfile rendering.
# Sourcing this helper has no network access or shell-option side effects.

_image_config_error() {
	printf '[ERROR] Image configuration: %s\n' "$*" >&2
	return 2
}

image_config_validate() {
	local config="${1:-}" maintainers="${2:-}"
	[[ -f "$config" && -f "$maintainers" ]] || {
		_image_config_error 'build and maintainer JSON files are required'; return 2;
	}
	if ! jq -e '
		def text: type == "string" and (explode | all(. >= 32 and . != 127));
		def url: text and test("^https://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?(/[A-Za-z0-9._~:/?@%&=+,!-]*)?$");
		def image: text and test("^[a-z0-9][a-z0-9._/-]*$");
		. as $config | type == "object" and .schema == 1 and
		(.image | image) and (.baseImage | image) and
		(.profiles | type == "object" and length > 0) and
		all(.profiles | to_entries[];
			(.key | text and test("^[a-z][a-z0-9_-]*$")) and
			(.value | type == "object") and
			(.value.suffix | text and test("^(-[a-z0-9][a-z0-9-]*)?$"))) and
		(.profiles.standard.suffix == "") and
		([.profiles[].suffix] | length == (unique | length)) and
		(has("defaultProfile") | not) and
		(.sources | type == "object") and
		(.sources.joomla_releases_url | url) and
		(.sources.joomla_repository | image) and
		(.sources.mcp_updates_url | url) and
		(.sources.jcb_updates | type == "object" and length > 0) and
		all(.sources.jcb_updates | to_entries[]; (.key | text and test("^[1-9][0-9]*$")) and (.value | url)) and
		(.labels | type == "object") and
		all(.labels | to_entries[]; (.key | text and test("^[A-Za-z0-9][A-Za-z0-9_.-]*$")) and (.value | text)) and
		(.packageDirectory | text and test("^/[A-Za-z0-9_-]+(/[A-Za-z0-9_-][A-Za-z0-9_.-]*)*$")) and
		(.environment | type == "object") and
		all(.environment | to_entries[]; (.key | text and test("^[A-Z_][A-Z0-9_]*$")) and (.value | text)) and
		all(["JOOMLA_SITE_NAME", "JOOMLA_ADMIN_USER", "JOOMLA_ADMIN_USERNAME", "JOOMLA_ADMIN_EMAIL", "JOOMLA_WEBROOT"][];
			. as $key | $config.environment[$key] | text and length > 0) and
		all(["JOOMLA_EXTENSIONS_PATHS", "JCB_VERSION", "JCB_SHA512", "JCB_PACKAGE", "JCB_INSTALL_DIR", "JCB_ZIP_PATH", "MCP_VERSION", "MCP_SHA512", "MCP_PACKAGE", "MCP_ZIP_PATH"][];
			. as $key | $config.environment | has($key) | not)
	' "$config" >/dev/null; then
		_image_config_error "invalid build JSON: $config"; return 2
	fi
	if ! jq -e '
		def text: type == "string" and length > 0 and (explode | all(. >= 32 and . != 127));
		type == "array" and length > 0 and
		all(.[]; type == "object" and (.firstname | text) and (.lastname | text) and
			(.email | text) and (.github | text))
	' "$maintainers" >/dev/null; then
		_image_config_error "invalid maintainer JSON: $maintainers"; return 2
	fi
}

image_profile_suffix() {
	local config="${1:-}" profile="${2:-}"
	jq -er --arg profile "$profile" '.profiles[$profile].suffix | select(type == "string")' "$config" || {
		_image_config_error "unknown image profile: $profile"; return 2;
	}
}

# Dockerfile ENV/LABEL quoting is not shell quoting. Escape Docker expansion
# separately; runtime RUN commands only expand already quoted environment values.
_image_docker_quote() {
	local value="$1"
	value="${value//\\/\\\\}"
	value="${value//\"/\\\"}"
	value="${value//\$/\\\$}"
	printf '"%s"' "$value"
}

_image_render_values() {
	local instruction="$1" json="$2" key value
	# Validated values contain no line breaks, so alternate key/value lines avoid
	# launching one JSON parser per environment variable in every matrix entry.
	while IFS= read -r key && IFS= read -r value; do
		printf '%s %s=%s\n' "$instruction" "$key" "$(_image_docker_quote "$value")"
	done < <(jq -r 'to_entries | sort_by(.key)[] | .key, .value' <<< "$json")
}

# Arguments: build.json, maintainers.json, resolved metadata as a JSON string.
# Metadata: {joomla, php, variant, profile, base_digest,
#            jcb: {version, url, sha512}, mcp: null | {version, url, sha512, ...}}.
# Output is a complete Dockerfile. Validation finishes before anything is emitted.
image_render_dockerfile() (
	local config_file="${1:-}" maintainers_file="${2:-}" metadata="${3:-}"
	local config joomla php variant profile digest suffix base_name package_dir
	local authors labels environment jcb mcp description extensions
	image_config_validate "$config_file" "$maintainers_file" || return 2
	config="$(jq -cS . "$config_file")" || return 2
	if ! jq -e --argjson config "$config" '
		def text: type == "string" and (explode | all(. >= 32 and . != 127));
		def version: text and test("^[0-9]+\\.[0-9]+\\.[0-9]+(-[A-Za-z0-9.-]+)?$");
		def package: type == "object" and (.version | version) and
			(.url | text and test("^https://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?(/[A-Za-z0-9._~:/?@%&=+,!-]*)?$")) and
			(.sha512 | text and test("^[a-fA-F0-9]{128}$"));
		type == "object" and (.joomla | version) and
		(.php | text and test("^[0-9]+\\.[0-9]+$")) and
		(.variant == "apache" or .variant == "fpm" or .variant == "fpm-alpine") and
		(.profile | type == "string") and (. as $m | $config.profiles | has($m.profile)) and
		(.base_digest | text and test("^sha256:[a-f0-9]{64}$")) and
		(.jcb | package) and (.mcp == null or (.mcp | package))
	' <<< "$metadata" >/dev/null; then
		_image_config_error 'invalid resolved image metadata'; return 2
	fi
	joomla="$(jq -r .joomla <<< "$metadata")"
	php="$(jq -r .php <<< "$metadata")"
	variant="$(jq -r .variant <<< "$metadata")"
	profile="$(jq -r .profile <<< "$metadata")"
	digest="$(jq -r .base_digest <<< "$metadata")"
	jcb="$(jq -c '.jcb | .sha512 |= ascii_downcase' <<< "$metadata")"
	mcp="$(jq -c 'if .mcp then .mcp | .sha512 |= ascii_downcase else null end' <<< "$metadata")"
	suffix="$(image_profile_suffix "$config_file" "$profile")" || return 2
	base_name="$(jq -r .baseImage <<< "$config"):$joomla-php$php-$variant$suffix"
	package_dir="$(jq -r .packageDirectory <<< "$config")"
	authors="$(jq -r 'map(.firstname + " " + .lastname + " <" + .email + "> (@" + .github + ")") | join(", ")' "$maintainers_file")"
	description="Joomla! v$joomla + Component Builder v$(jq -r .version <<< "$jcb")"
	[[ "$mcp" == null ]] || description+=" + JoomEngine MCP v$(jq -r .version <<< "$mcp")"
	labels="$(jq -cS --arg authors "$authors" --arg description "$description" \
		--argjson jcb "$jcb" --argjson mcp "$mcp" --arg base "$base_name" --arg digest "$digest" --arg profile "$profile" '
		.labels + {
			"org.opencontainers.image.authors": $authors,
			"org.opencontainers.image.description": $description,
			"org.opencontainers.image.version": $jcb.version,
			"org.opencontainers.image.base.name": $base,
			"org.opencontainers.image.base.digest": $digest,
			"org.joomengine.profile": $profile
		} + (if $mcp == null then {} else {
			"org.joomengine.mcp.version": $mcp.version,
			"org.joomengine.mcp.sha512": $mcp.sha512,
			"org.joomengine.mcp.source": $mcp.url
		} end)' <<< "$config")" || return 2
	extensions="$package_dir/jcb.zip"
	[[ "$mcp" == null ]] || extensions+=";$package_dir/mcp.zip"
	environment="$(jq -cS --argjson jcb "$jcb" --argjson mcp "$mcp" --arg directory "$package_dir" \
		--arg extensions "$extensions" '
		.environment + {
			JCB_VERSION: $jcb.version, JCB_SHA512: $jcb.sha512, JCB_PACKAGE: $jcb.url,
			JCB_INSTALL_DIR: $directory, JCB_ZIP_PATH: ($directory + "/jcb.zip"),
			JOOMLA_EXTENSIONS_PATHS: $extensions
		} +
		(if $mcp == null then {} else {
			MCP_VERSION: $mcp.version, MCP_SHA512: $mcp.sha512, MCP_PACKAGE: $mcp.url,
			MCP_ZIP_PATH: ($directory + "/mcp.zip")
		} end)' <<< "$config")" || return 2

	printf '# Generated by src/bin/joomengine.sh; edit conf/build.json and source metadata.\n'
	printf 'FROM %s@%s\n\n' "$base_name" "$digest"
	_image_render_values LABEL "$labels"
	printf '\n'
	_image_render_values ENV "$environment"
	cat <<'DOCKERFILE'

# Packages are verified at build time and retained outside the mounted webroot.
RUN set -eux; \
	mkdir -p "$JCB_INSTALL_DIR"; \
	curl --fail --show-error --silent --location --retry 3 --connect-timeout 15 --max-time 300 \
		--proto '=https' --proto-redir '=https' "$JCB_PACKAGE" --output "$JCB_INSTALL_DIR/jcb.zip"; \
	printf '%s  %s\n' "$JCB_SHA512" "$JCB_INSTALL_DIR/jcb.zip" | sha512sum -c -; \
	chown -R www-data:www-data "$JCB_INSTALL_DIR"
DOCKERFILE
	if [[ "$mcp" != null ]]; then
		cat <<'DOCKERFILE'

RUN set -eux; \
	curl --fail --show-error --silent --location --retry 3 --connect-timeout 15 --max-time 300 \
		--proto '=https' --proto-redir '=https' "$MCP_PACKAGE" --output "$JCB_INSTALL_DIR/mcp.zip"; \
	printf '%s  %s\n' "$MCP_SHA512" "$JCB_INSTALL_DIR/mcp.zip" | sha512sum -c -; \
	chown www-data:www-data "$JCB_INSTALL_DIR/mcp.zip"
DOCKERFILE
	fi
	printf '\n# Joomla owns initialization and server startup; inherit ENTRYPOINT and CMD.\n'
)
