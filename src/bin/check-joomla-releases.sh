#!/usr/bin/env bash
set -euo pipefail

# Poll Joomla's stable-release feed and verify the published Docker registry
# indexes before advancing base versions or refreshing their digest state.

SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

if REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
	:
else
	REPO_ROOT="$(realpath "$SCRIPT_DIR/../..")"
fi

VERSIONS_FILE="$REPO_ROOT/conf/versions.json"
STATE_FILE="$REPO_ROOT/conf/upstream-images.json"
RELEASES_FILE=""
DOCKER_TAGS_FILE=""
OFFICIAL_IMAGES_FILE=""
QUIET="no"
REFRESH_CURRENT="no"

JOOMLA_RELEASES_URL="${JOOMLA_RELEASES_URL:-https://downloads.joomla.org/api/v1/latest/cms}"
DOCKER_REGISTRY_API_BASE="${DOCKER_REGISTRY_API_BASE:-https://registry-1.docker.io/v2/library/joomla}"
DOCKER_REGISTRY_TOKEN_URL="${DOCKER_REGISTRY_TOKEN_URL:-https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/joomla:pull}"

show_help() {
	cat <<'EOF'
Usage: check-joomla-releases.sh [options]

Options:
      --versions-file PATH     Joomla build matrix to inspect and update
      --state-file PATH        Persist verified image-index and platform digests
      --refresh-current        Verify configured versions without checking releases
      --releases-file PATH     Read Joomla release data from a local JSON file
      --docker-tags-file PATH  Read Docker tag data from a local JSON file
      --official-images-file PATH
                              Deprecated compatibility option; metadata is unused
  -q, --quiet                  Suppress informational output
  -h, --help                   Show this help and exit

The local data options provide deterministic, network-free execution for tests.
The Docker fixture format is the Docker Hub list response shape: a top-level
"results" array containing tag objects with "name" and "images" fields.
Live verification reads and hashes the published Docker registry index. Its
runnable Linux descriptors determine the available platforms; official-images
architecture declarations can include platforms that are not yet published.

Exit behavior:
  0  Successful update, no update, or a release whose Docker matrix is pending
  1  Invalid input, an upstream/API failure, or an unsafe update condition
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--versions-file)
			[[ $# -ge 2 ]] || {
				echo "[ERROR] --versions-file requires a path" >&2
				exit 1
			}
			VERSIONS_FILE="$2"
			shift 2
			;;
		--state-file)
			[[ $# -ge 2 ]] || {
				echo "[ERROR] --state-file requires a path" >&2
				exit 1
			}
			STATE_FILE="$2"
			shift 2
			;;
		--refresh-current)
			REFRESH_CURRENT="yes"
			shift
			;;
		--releases-file)
			[[ $# -ge 2 ]] || {
				echo "[ERROR] --releases-file requires a path" >&2
				exit 1
			}
			RELEASES_FILE="$2"
			shift 2
			;;
		--docker-tags-file)
			[[ $# -ge 2 ]] || {
				echo "[ERROR] --docker-tags-file requires a path" >&2
				exit 1
			}
			DOCKER_TAGS_FILE="$2"
			shift 2
			;;
		--official-images-file)
			[[ $# -ge 2 ]] || {
				echo "[ERROR] --official-images-file requires a path" >&2
				exit 1
			}
			OFFICIAL_IMAGES_FILE="$2"
			shift 2
			;;
		-q|--quiet)
			QUIET="yes"
			shift
			;;
		-h|--help)
			show_help
			exit 0
			;;
		*)
			echo "[ERROR] Unknown option: $1" >&2
			show_help >&2
			exit 1
			;;
	esac
done

log() {
	[[ "$QUIET" == "yes" ]] || printf '%s\n' "$*"
}

fail() {
	echo "[ERROR] $*" >&2
	exit 1
}

for command_name in awk jq sort realpath mktemp cmp chmod mv sha256sum; do
	command -v "$command_name" >/dev/null 2>&1 || fail "Missing required command: $command_name"
done

if [[ ( "$REFRESH_CURRENT" == "no" && -z "$RELEASES_FILE" ) || -z "$DOCKER_TAGS_FILE" ]]; then
	command -v curl >/dev/null 2>&1 || fail "Missing required command: curl"
fi

[[ -f "$VERSIONS_FILE" ]] || fail "Versions file does not exist: $VERSIONS_FILE"
[[ -r "$VERSIONS_FILE" ]] || fail "Versions file is not readable: $VERSIONS_FILE"

if [[ -e "$STATE_FILE" && ! -f "$STATE_FILE" ]]; then
	fail "Upstream image state path is not a regular file: $STATE_FILE"
fi

if [[ -f "$STATE_FILE" && ! -r "$STATE_FILE" ]]; then
	fail "Upstream image state file is not readable: $STATE_FILE"
fi

if [[ -n "$RELEASES_FILE" ]]; then
	[[ -f "$RELEASES_FILE" ]] || fail "Releases file does not exist: $RELEASES_FILE"
	[[ -r "$RELEASES_FILE" ]] || fail "Releases file is not readable: $RELEASES_FILE"
fi

if [[ -n "$DOCKER_TAGS_FILE" ]]; then
	[[ -f "$DOCKER_TAGS_FILE" ]] || fail "Docker tags file does not exist: $DOCKER_TAGS_FILE"
	[[ -r "$DOCKER_TAGS_FILE" ]] || fail "Docker tags file is not readable: $DOCKER_TAGS_FILE"
fi

if [[ -n "$OFFICIAL_IMAGES_FILE" ]]; then
	[[ -f "$OFFICIAL_IMAGES_FILE" ]] || fail "Official-images file does not exist: $OFFICIAL_IMAGES_FILE"
	[[ -r "$OFFICIAL_IMAGES_FILE" ]] || fail "Official-images file is not readable: $OFFICIAL_IMAGES_FILE"
fi

if ! jq -e '
	type == "object" and
	length > 0 and
	all(
		to_entries[];
		.key as $major |
		($major | test("^[0-9]+$")) and
		(.value | type == "object") and
		(.value.php |
			type == "array" and
			length > 0 and
			all(.[]; type == "string" and test("^[0-9]+\\.[0-9]+$"))) and
		(.value.joomla |
			type == "string" and
			test("^" + $major + "\\.[0-9]+\\.[0-9]+$")) and
		(.value.variants |
			type == "array" and
			length > 0 and
			all(.[]; type == "string" and test("^[a-z0-9][a-z0-9._-]*$")))
	)
' "$VERSIONS_FILE" >/dev/null; then
	fail "Invalid Joomla build matrix: $VERSIONS_FILE"
fi

if [[ -f "$STATE_FILE" ]] && ! jq -e '
	def digest:
		type == "string" and test("^sha256:[a-f0-9]{64}$");
	def platform:
		type == "string" and
		(split("/") as $parts |
			($parts | length) >= 2 and
			($parts | length) <= 3 and
			$parts[0] == "linux" and
			($parts[1] | test("^[a-z0-9][a-z0-9._-]*$") and
				. != "unknown" and
				. != "i386" and
				. != "x86_64" and
				. != "aarch64") and
			(if $parts[1] == "arm" or $parts[1] == "arm64" then
				($parts | length) == 3 and ($parts[2] | test("^v[0-9]+$"))
			elif ($parts | length) == 3 then
				($parts[2] | test("^[a-z0-9][a-z0-9._-]*$"))
			else
				true
			end));
	type == "object" and
	.repository == "library/joomla" and
	(.tags | type == "object") and
	(if .schema == 1 then
		all(
			.tags | to_entries[];
			(.key | test("^[0-9]+\\.[0-9]+\\.[0-9]+-php[0-9]+\\.[0-9]+-[a-z0-9][a-z0-9._-]*$")) and
			(.value | digest)
		)
	elif .schema == 2 then
		all(
			.tags | to_entries[];
			(.key | test("^[0-9]+\\.[0-9]+\\.[0-9]+-php[0-9]+\\.[0-9]+-[a-z0-9][a-z0-9._-]*$")) and
			(.value | type == "object") and
			(.value | keys | sort) == ["index_digest", "platforms"] and
			(.value.index_digest | digest) and
			(.value.platforms | type == "object" and length > 0) and
			all(
				.value.platforms | to_entries[];
				(.key | platform) and (.value | digest)
			)
		)
	else
		false
	end)
' "$STATE_FILE" >/dev/null; then
	fail "Invalid upstream image state: $STATE_FILE"
fi

RELEASES_TMP=""
REGISTRY_TOKEN_TMP=""
REGISTRY_MANIFEST_TMP=""
REGISTRY_HEADERS_TMP=""
REGISTRY_TOKEN=""
TAG_TMP=""
OUTPUT_TMP=""
STATE_TMP=""

cleanup() {
	[[ -z "$RELEASES_TMP" ]] || rm -f -- "$RELEASES_TMP"
	[[ -z "$REGISTRY_TOKEN_TMP" ]] || rm -f -- "$REGISTRY_TOKEN_TMP"
	[[ -z "$REGISTRY_MANIFEST_TMP" ]] || rm -f -- "$REGISTRY_MANIFEST_TMP"
	[[ -z "$REGISTRY_HEADERS_TMP" ]] || rm -f -- "$REGISTRY_HEADERS_TMP"
	[[ -z "$TAG_TMP" ]] || rm -f -- "$TAG_TMP"
	[[ -z "$OUTPUT_TMP" ]] || rm -f -- "$OUTPUT_TMP"
	[[ -z "$STATE_TMP" ]] || rm -f -- "$STATE_TMP"
}
trap cleanup EXIT

if [[ "$REFRESH_CURRENT" == "yes" ]]; then
	RELEASES_SOURCE=""
elif [[ -n "$RELEASES_FILE" ]]; then
	RELEASES_SOURCE="$RELEASES_FILE"
else
	RELEASES_TMP="$(mktemp)"
	log "Checking Joomla stable releases: $JOOMLA_RELEASES_URL"

	if ! curl \
		--fail-with-body \
		--silent \
		--show-error \
		--location \
		--retry 3 \
		--retry-delay 2 \
		--retry-connrefused \
		--connect-timeout 15 \
		--max-time 60 \
		--output "$RELEASES_TMP" \
		"$JOOMLA_RELEASES_URL"; then
		fail "Unable to retrieve Joomla stable release data"
	fi

	RELEASES_SOURCE="$RELEASES_TMP"
fi

if [[ "$REFRESH_CURRENT" == "no" ]] && ! jq -e '
	type == "object" and
	(.branches | type == "array" and length > 0) and
	all(
		.branches[];
		type == "object" and
		(.branch | type == "string") and
		(.version | type == "string")
	)
' "$RELEASES_SOURCE" >/dev/null; then
	fail "Joomla stable release response does not match the expected schema"
fi

if [[ -n "$DOCKER_TAGS_FILE" ]] && ! jq -e '
	type == "object" and
	(.results | type == "array") and
	all(
		.results[];
		type == "object" and
		(.name | type == "string") and
		(.digest | type == "string" and test("^sha256:[a-f0-9]{64}$")) and
		(.images | type == "array") and
		all(
			.images[];
			(.digest | type == "string" and test("^sha256:[a-f0-9]{64}$")) and
			(.status | type == "string") and
			(.os | type == "string") and
			(.architecture | type == "string") and
			(.variant == null or (.variant | type == "string"))
		)
	)
' "$DOCKER_TAGS_FILE" >/dev/null; then
	fail "Docker tag fixture does not match the expected schema"
fi

TAG_TMP="$(mktemp)"

normalize_docker_tag_record() {
	local source="$1"
	local expected_tag="$2"
	local source_kind="${3:-fixture}"
	local index_digest

	if ! jq -e --arg tag "$expected_tag" '
		type == "object" and
		.name == $tag and
		(.digest | type == "string" and test("^sha256:[a-f0-9]{64}$")) and
		(.images | type == "array") and
		all(
			.images[];
			(.digest | type == "string" and test("^sha256:[a-f0-9]{64}$")) and
			(.status | type == "string") and
			(.os | type == "string") and
			(.architecture | type == "string") and
			(.variant == null or (.variant | type == "string"))
		)
	' "$source" >/dev/null; then
		echo "[ERROR] Invalid Docker image record for '$expected_tag'" >&2
		return 2
	fi

	if ! jq -e '
		any(
			.images[]?;
			(.status | ascii_downcase) == "active" and
			(.os | ascii_downcase) == "linux" and
			(.architecture | ascii_downcase) != "unknown"
		)
	' "$source" >/dev/null; then
		return 1
	fi

	index_digest="$(jq -r '.digest' "$source")"
	if ! jq -ce --arg index_digest "$index_digest" --arg source_kind "$source_kind" '
		def normalized_architecture:
			ascii_downcase |
			if . == "x86_64" or . == "x86-64" then "amd64"
			elif . == "aarch64" then "arm64"
			elif . == "i386" then "386"
			else .
			end;
		def normalized_variant:
			ascii_downcase |
			if test("^[0-9]+$") then "v" + . else . end;
		def runnable:
			(.status | ascii_downcase) == "active" and
			(.os | ascii_downcase) == "linux" and
			(.architecture | ascii_downcase) != "unknown";
		def platform_entry:
			(.architecture | normalized_architecture) as $raw_architecture |
			(.variant // "" | normalized_variant) as $raw_variant |
			(if $raw_architecture == "amd64" and $raw_variant == "v1" then
				{architecture: "amd64", variant: ""}
			elif $raw_architecture == "arm" and $raw_variant == "" then
				{architecture: "arm", variant: "v7"}
			elif $raw_architecture == "arm64" and $raw_variant == "" then
				{architecture: "arm64", variant: "v8"}
			elif $source_kind == "fixture" and $raw_architecture == "arm" and $raw_variant == "v8" then
				{architecture: "arm64", variant: "v8"}
			else
				{architecture: $raw_architecture, variant: $raw_variant}
			end) as $normalized |
			if ($normalized.architecture | test("^[a-z0-9][a-z0-9._-]*$")) | not then
				error("invalid architecture")
			elif $normalized.architecture == "unknown" then
				error("unknown architecture")
			elif ($normalized.architecture == "arm" or $normalized.architecture == "arm64") and
				($normalized.variant | test("^v[0-9]+$") | not) then
				error("invalid ARM variant")
			elif $normalized.variant != "" and
				($normalized.variant | test("^[a-z0-9][a-z0-9._-]*$") | not) then
				error("invalid variant")
			else
				{
					platform: (
						"linux/" + $normalized.architecture +
						(if $normalized.variant == "" then "" else "/" + $normalized.variant end)
					),
					digest: .digest
				}
			end;
		[
			.images[] |
			select(runnable) |
			platform_entry
		] |
		sort_by(.platform) as $entries |
		if any($entries | group_by(.platform)[]; length > 1) then
			error("duplicate canonical platform")
		else
			{
				index_digest: $index_digest,
				platforms: (reduce $entries[] as $entry ({}; . + {($entry.platform): $entry.digest}))
			}
		end
	' "$source" 2>/dev/null; then
		echo "[ERROR] Conflicting or invalid Docker platforms for '$expected_tag'" >&2
		return 2
	fi
}

docker_fixture_tag_record() {
	local tag="$1"
	local match_count

	match_count="$(jq -r --arg tag "$tag" '[.results[] | select(.name == $tag)] | length' "$DOCKER_TAGS_FILE")"
	if [[ "$match_count" == "0" ]]; then
		return 1
	fi
	if [[ "$match_count" != "1" ]]; then
		echo "[ERROR] Docker fixture contains duplicate entries for '$tag'" >&2
		return 2
	fi

	jq --arg tag "$tag" '.results[] | select(.name == $tag)' "$DOCKER_TAGS_FILE" > "$TAG_TMP"
	normalize_docker_tag_record "$TAG_TMP" "$tag"
}

initialize_registry() {
	REGISTRY_TOKEN_TMP="$(mktemp)"
	REGISTRY_MANIFEST_TMP="$(mktemp)"
	REGISTRY_HEADERS_TMP="$(mktemp)"

	if ! curl \
		--fail-with-body \
		--silent \
		--show-error \
		--location \
		--retry 3 \
		--retry-delay 2 \
		--retry-connrefused \
		--connect-timeout 15 \
		--max-time 60 \
		--output "$REGISTRY_TOKEN_TMP" \
		"$DOCKER_REGISTRY_TOKEN_URL"; then
		fail "Unable to obtain an anonymous Docker registry pull token"
	fi

	if ! REGISTRY_TOKEN="$(jq -er '
		(.token // .access_token) |
		select(type == "string" and length > 0 and (test("[[:space:][:cntrl:]]") | not))
	' "$REGISTRY_TOKEN_TMP")"; then
		fail "Docker registry returned an invalid pull token"
	fi
}

docker_registry_tag_record() {
	local tag="$1"
	local curl_status=0
	local http_status=""
	local index_digest
	local body_digest
	local url="${DOCKER_REGISTRY_API_BASE%/}/manifests/${tag}"

	: > "$REGISTRY_MANIFEST_TMP"
	: > "$REGISTRY_HEADERS_TMP"

	if http_status="$(
		curl \
			--fail-with-body \
			--silent \
			--show-error \
			--location \
			--retry 3 \
			--retry-delay 2 \
			--retry-connrefused \
			--connect-timeout 15 \
			--max-time 60 \
			--header "Authorization: Bearer $REGISTRY_TOKEN" \
			--header 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
			--output "$REGISTRY_MANIFEST_TMP" \
			--dump-header "$REGISTRY_HEADERS_TMP" \
			--write-out '%{http_code}' \
			"$url" \
			2>/dev/null
	)"; then
		curl_status=0
	else
		curl_status=$?
	fi

	if [[ "$http_status" == "404" ]]; then
		return 1
	fi

	if [[ "$curl_status" -ne 0 || "$http_status" != "200" ]]; then
		echo "[ERROR] Docker registry request failed for '$tag' (HTTP ${http_status:-unknown}, curl $curl_status)" >&2
		return 2
	fi

	# Hash the original response bytes, before parsing or reformatting JSON.
	# A Docker Hub tag page and its cached per-platform status are not evidence
	# of the exact image index that a pull will resolve to.
	index_digest="$(awk '
		tolower($0) ~ /^docker-content-digest:[[:space:]]*/ {
			sub(/^[^:]*:[[:space:]]*/, "")
			sub(/[[:space:]]*$/, "")
			digest = $0
		}
		END { print digest }
	' "$REGISTRY_HEADERS_TMP")"
	if [[ ! "$index_digest" =~ ^sha256:[a-f0-9]{64}$ ]]; then
		echo "[ERROR] Docker registry returned no valid index digest for '$tag'" >&2
		return 2
	fi
	body_digest="sha256:$(sha256sum "$REGISTRY_MANIFEST_TMP" | awk '{ print $1 }')"
	if [[ "$body_digest" != "$index_digest" ]]; then
		echo "[ERROR] Docker registry index digest verification failed for '$tag'" >&2
		return 2
	fi

	if ! jq -e '
		def digest:
			type == "string" and test("^sha256:[a-f0-9]{64}$");
		type == "object" and
		.schemaVersion == 2 and
		(.mediaType == "application/vnd.oci.image.index.v1+json" or
			.mediaType == "application/vnd.docker.distribution.manifest.list.v2+json") and
		(.manifests | type == "array" and length > 0) and
		all(
			.manifests[];
			type == "object" and
			(.mediaType == "application/vnd.oci.image.manifest.v1+json" or
				.mediaType == "application/vnd.docker.distribution.manifest.v2+json") and
			(.digest | digest) and
			(.size | type == "number" and . > 0 and floor == .) and
			(.platform | type == "object") and
			(.platform.os | type == "string" and test("^[a-zA-Z0-9][a-zA-Z0-9._-]*$")) and
			(.platform.architecture | type == "string" and test("^[a-zA-Z0-9][a-zA-Z0-9._-]*$")) and
			(.platform.variant == null or (.platform.variant | type == "string")) and
			((.platform.os | ascii_downcase) != "linux" or
				(.platform.architecture | ascii_downcase) != "unknown")
		)
	' "$REGISTRY_MANIFEST_TMP" >/dev/null; then
		echo "[ERROR] Docker registry returned an invalid image index for '$tag'" >&2
		return 2
	fi

	if ! jq --arg tag "$tag" --arg digest "$index_digest" '{
		name: $tag,
		digest: $digest,
		images: [.manifests[] | {
			digest,
			status: "active",
			os: .platform.os,
			architecture: .platform.architecture,
			variant: .platform.variant
		}]
	}' "$REGISTRY_MANIFEST_TMP" > "$TAG_TMP"; then
		return 2
	fi

	local record
	if ! record="$(normalize_docker_tag_record "$TAG_TMP" "$tag" registry)"; then
		echo "[ERROR] Docker registry index has no valid runnable Linux platform set for '$tag'" >&2
		return 2
	fi
	printf '%s\n' "$record"
}

docker_tag_record() {
	local tag="$1"

	if [[ -n "$DOCKER_TAGS_FILE" ]]; then
		docker_fixture_tag_record "$tag"
	else
		docker_registry_tag_record "$tag"
	fi
}

version_is_newer() {
	local candidate="$1"
	local current="$2"
	local highest

	[[ "$candidate" != "$current" ]] || return 1
	highest="$(printf '%s\n%s\n' "$candidate" "$current" | sort -V | tail -n 1)"
	[[ "$highest" == "$candidate" ]]
}

write_github_output() {
	local key="$1"
	local value="$2"

	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
	fi
}

join_with_commas() {
	local IFS=,
	printf '%s' "$*"
}

mapfile -t MAJORS < <(jq -r 'keys[]' "$VERSIONS_FILE" | sort -V)

declare -A NEW_VERSION_BY_MAJOR=()
declare -A DESIRED_RECORD_BY_TAG=()
declare -A WAITING_MAJOR_SEEN=()
declare -a UPDATED_MAJORS=()
declare -a WAITING_MAJORS=()
declare -a COLLECTED_TAGS=()
declare -a COLLECTED_RECORDS=()

COLLECTION_READY="yes"
mark_major_waiting() {
	local major="$1"

	if [[ -z "${WAITING_MAJOR_SEEN[$major]:-}" ]]; then
		WAITING_MAJOR_SEEN["$major"]=1
		WAITING_MAJORS+=("$major")
	fi
}

collect_matrix_records() {
	local major="$1"
	local version="$2"
	local role="$3"
	local php_version
	local variant
	local tag
	local record
	local tag_status
	local -a php_versions=()
	local -a variants=()

	COLLECTED_TAGS=()
	COLLECTED_RECORDS=()
	COLLECTION_READY="yes"

	mapfile -t php_versions < <(jq -r --arg major "$major" '.[$major].php[]' "$VERSIONS_FILE")
	mapfile -t variants < <(jq -r --arg major "$major" '.[$major].variants[]' "$VERSIONS_FILE")

	for php_version in "${php_versions[@]}"; do
		for variant in "${variants[@]}"; do
			tag="${version}-php${php_version}-${variant}"

			if record="$(docker_tag_record "$tag")"; then
				:
			else
				tag_status=$?
				if [[ "$tag_status" -ne 1 ]]; then
					return 2
				fi

				COLLECTION_READY="no"
				if [[ "$role" == "current" ]]; then
					echo "[ERROR] Currently configured Docker tag is unavailable: joomla:$tag" >&2
					return 2
				fi

				log "Joomla $major: waiting for official Docker tag joomla:$tag"
				return 0
			fi

			COLLECTED_TAGS+=("$tag")
			COLLECTED_RECORDS+=("$record")
			log "Joomla $major: Docker tag ready on $(jq -r '.platforms | length' <<< "$record") platforms: joomla:$tag"
		done
	done
}

add_collected_records() {
	local index

	for index in "${!COLLECTED_TAGS[@]}"; do
		DESIRED_RECORD_BY_TAG["${COLLECTED_TAGS[$index]}"]="${COLLECTED_RECORDS[$index]}"
	done
}

if [[ -z "$DOCKER_TAGS_FILE" ]]; then
	initialize_registry
fi

for major in "${MAJORS[@]}"; do
	current_version="$(jq -r --arg major "$major" '.[$major].joomla' "$VERSIONS_FILE")"
	candidate_version=""
	if [[ "$REFRESH_CURRENT" == "yes" ]]; then
		log "Joomla $major: refreshing configured version $current_version"
	else
		release_count="$(
			jq -r --arg branch "Joomla! $major" \
				'[.branches[] | select(.branch == $branch)] | length' \
				"$RELEASES_SOURCE"
		)"

		if [[ "$release_count" == "0" ]]; then
			log "Joomla $major: no stable release entry; keeping $current_version"
		elif [[ "$release_count" != "1" ]]; then
			fail "Joomla stable release response contains duplicate entries for major $major"
		else
			candidate_version="$(
				jq -r --arg branch "Joomla! $major" \
					'.branches[] | select(.branch == $branch) | .version' \
					"$RELEASES_SOURCE"
			)"

			if [[ "$candidate_version" =~ ^${major}\.[0-9]+\.[0-9]+[-+] ]]; then
				log "Joomla $major: upstream entry $candidate_version is not stable; ignoring it"
				candidate_version=""
			elif [[ ! "$candidate_version" =~ ^${major}\.[0-9]+\.[0-9]+$ ]]; then
				fail "Invalid stable Joomla $major version from upstream: $candidate_version"
			elif [[ "$candidate_version" == "$current_version" ]]; then
				log "Joomla $major: $current_version is current"
				candidate_version=""
			elif ! version_is_newer "$candidate_version" "$current_version"; then
				log "Joomla $major: upstream reports older $candidate_version; refusing to downgrade $current_version"
				candidate_version=""
			fi
		fi

	fi

	if ! collect_matrix_records "$major" "$current_version" "current"; then
		fail "Unable to verify the current Joomla $major Docker image matrix"
	fi
	current_tags=("${COLLECTED_TAGS[@]}")
	add_collected_records

	if [[ -n "$candidate_version" ]]; then
		if ! collect_matrix_records "$major" "$candidate_version" "candidate"; then
			fail "Unable to verify the candidate Joomla $major Docker image matrix"
		fi

		if [[ "$COLLECTION_READY" == "yes" ]]; then
			for tag in "${current_tags[@]}"; do
				unset 'DESIRED_RECORD_BY_TAG[$tag]'
			done
			add_collected_records
			NEW_VERSION_BY_MAJOR["$major"]="$candidate_version"
			UPDATED_MAJORS+=("$major")
			log "Joomla $major: ready to advance $current_version -> $candidate_version"
		else
			mark_major_waiting "$major"
		fi
	fi
done

VERSIONS_CHANGED="no"
DIGESTS_CHANGED="no"

if [[ "${#UPDATED_MAJORS[@]}" -gt 0 ]]; then
	updates_json='{}'
	for major in "${UPDATED_MAJORS[@]}"; do
		updates_json="$(
			jq -cn \
				--argjson current "$updates_json" \
				--arg major "$major" \
				--arg version "${NEW_VERSION_BY_MAJOR[$major]}" \
				'$current + {($major): $version}'
		)"
	done

	OUTPUT_TMP="$(mktemp "${VERSIONS_FILE}.tmp.XXXXXX")"

	if ! jq -r --argjson updates "$updates_json" '
		def inline_value:
			if type == "array" then
				"[" + (map(tojson) | join(", ")) + "]"
			else
				tojson
			end;

		reduce ($updates | to_entries[]) as $update
			(.; .[$update.key].joomla = $update.value) |
		"{\n" +
		(
			to_entries |
			map(
				"\t\(.key | tojson): {\n" +
				(
					.value |
					to_entries |
					map("\t\t\(.key | tojson): \(.value | inline_value)") |
					join(",\n")
				) +
				"\n\t}"
			) |
			join(",\n")
		) +
		"\n}"
	' "$VERSIONS_FILE" > "$OUTPUT_TMP"; then
		fail "Unable to render the updated Joomla build matrix"
	fi

	if ! jq -e . "$OUTPUT_TMP" >/dev/null; then
		fail "Refusing to replace versions file with invalid JSON"
	fi

	chmod --reference="$VERSIONS_FILE" "$OUTPUT_TMP"
	if cmp -s "$VERSIONS_FILE" "$OUTPUT_TMP"; then
		fail "Release updates were selected but produced no versions file change"
	fi

	VERSIONS_CHANGED="yes"
fi

desired_tags_json='{}'
if [[ "${#DESIRED_RECORD_BY_TAG[@]}" -gt 0 ]]; then
	mapfile -t desired_tags < <(printf '%s\n' "${!DESIRED_RECORD_BY_TAG[@]}" | sort)
	for tag in "${desired_tags[@]}"; do
		desired_tags_json="$(
			jq -cn \
				--argjson current "$desired_tags_json" \
				--arg tag "$tag" \
				--argjson record "${DESIRED_RECORD_BY_TAG[$tag]}" \
				'$current + {($tag): $record}'
		)"
	done
fi

STATE_TMP="$(mktemp "${STATE_FILE}.tmp.XXXXXX")"
jq --tab -n \
	--argjson tags "$desired_tags_json" \
	'{schema: 2, repository: "library/joomla", tags: $tags}' \
	> "$STATE_TMP"

if ! jq -e . "$STATE_TMP" >/dev/null; then
	fail "Refusing to replace upstream image state with invalid JSON"
fi

if [[ -f "$STATE_FILE" ]]; then
	chmod --reference="$STATE_FILE" "$STATE_TMP"
else
	chmod 0644 "$STATE_TMP"
fi

if [[ ! -f "$STATE_FILE" ]] || ! cmp -s "$STATE_FILE" "$STATE_TMP"; then
	DIGESTS_CHANGED="yes"
else
	rm -f -- "$STATE_TMP"
	STATE_TMP=""
fi

# Both files are fully rendered and validated before either replacement occurs.
if [[ "$VERSIONS_CHANGED" == "yes" ]]; then
	mv -f -- "$OUTPUT_TMP" "$VERSIONS_FILE"
	OUTPUT_TMP=""
	log "Updated Joomla base versions for majors: $(join_with_commas "${UPDATED_MAJORS[@]}")"
fi

if [[ "$DIGESTS_CHANGED" == "yes" ]]; then
	mv -f -- "$STATE_TMP" "$STATE_FILE"
	STATE_TMP=""
	log "Updated official Joomla base image digests"
fi

if [[ "$VERSIONS_CHANGED" == "yes" || "$DIGESTS_CHANGED" == "yes" ]]; then
	CHANGED="yes"
else
	CHANGED="no"
	log "No Joomla base image updates are ready."
fi

write_github_output "changed" "$CHANGED"
write_github_output "versions_changed" "$VERSIONS_CHANGED"
write_github_output "digests_changed" "$DIGESTS_CHANGED"
write_github_output "updated_majors" "$(join_with_commas "${UPDATED_MAJORS[@]}")"
write_github_output "waiting_majors" "$(join_with_commas "${WAITING_MAJORS[@]}")"
