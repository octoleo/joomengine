#!/usr/bin/env bash
set -euo pipefail

# Poll Joomla's authoritative stable-release feed and advance the Joomla base
# versions only after every configured official Docker image is available.

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

JOOMLA_RELEASES_URL="${JOOMLA_RELEASES_URL:-https://downloads.joomla.org/api/v1/latest/cms}"
DOCKER_HUB_TAG_API_BASE="${DOCKER_HUB_TAG_API_BASE:-https://hub.docker.com/v2/namespaces/library/repositories/joomla/tags}"
OFFICIAL_IMAGES_URL="${OFFICIAL_IMAGES_URL:-https://raw.githubusercontent.com/docker-library/official-images/master/library/joomla}"

show_help() {
	cat <<'EOF'
Usage: check-joomla-releases.sh [options]

Options:
      --versions-file PATH     Joomla build matrix to inspect and update
      --state-file PATH        Persist verified image-index and platform digests
      --releases-file PATH     Read Joomla release data from a local JSON file
      --docker-tags-file PATH  Read Docker tag data from a local JSON file
      --official-images-file PATH
                              Read official-images metadata from a local file
  -q, --quiet                  Suppress informational output
  -h, --help                   Show this help and exit

The local data options provide deterministic, network-free execution for tests.
The Docker fixture format is the Docker Hub list response shape: a top-level
"results" array containing tag objects with "name" and "images" fields.
The official-images fixture uses the docker-library/official-images library-file
format, including unique "Tags" and "Architectures" fields per image stanza.

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

for command_name in awk jq sort realpath mktemp cmp chmod mv; do
	command -v "$command_name" >/dev/null 2>&1 || fail "Missing required command: $command_name"
done

if [[ -z "$RELEASES_FILE" || -z "$DOCKER_TAGS_FILE" || -z "$OFFICIAL_IMAGES_FILE" ]]; then
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
OFFICIAL_IMAGES_TMP=""
TAG_TMP=""
OUTPUT_TMP=""
STATE_TMP=""

cleanup() {
	[[ -z "$RELEASES_TMP" ]] || rm -f -- "$RELEASES_TMP"
	[[ -z "$OFFICIAL_IMAGES_TMP" ]] || rm -f -- "$OFFICIAL_IMAGES_TMP"
	[[ -z "$TAG_TMP" ]] || rm -f -- "$TAG_TMP"
	[[ -z "$OUTPUT_TMP" ]] || rm -f -- "$OUTPUT_TMP"
	[[ -z "$STATE_TMP" ]] || rm -f -- "$STATE_TMP"
}
trap cleanup EXIT

if [[ -n "$RELEASES_FILE" ]]; then
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

if ! jq -e '
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

if [[ -n "$OFFICIAL_IMAGES_FILE" ]]; then
	OFFICIAL_IMAGES_SOURCE="$OFFICIAL_IMAGES_FILE"
else
	OFFICIAL_IMAGES_TMP="$(mktemp)"
	log "Checking official Joomla image metadata: $OFFICIAL_IMAGES_URL"

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
		--output "$OFFICIAL_IMAGES_TMP" \
		"$OFFICIAL_IMAGES_URL"; then
		fail "Unable to retrieve official Joomla image metadata"
	fi

	OFFICIAL_IMAGES_SOURCE="$OFFICIAL_IMAGES_TMP"
fi

[[ -s "$OFFICIAL_IMAGES_SOURCE" ]] || fail "Official Joomla image metadata is empty"

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

normalize_official_architecture() {
	local architecture="${1,,}"

	case "$architecture" in
		amd64)
			printf '%s\n' "linux/amd64"
			;;
		i386)
			printf '%s\n' "linux/386"
			;;
		arm32v[0-9]*)
			[[ "$architecture" =~ ^arm32v([0-9]+)$ ]] || return 1
			printf 'linux/arm/v%s\n' "${BASH_REMATCH[1]}"
			;;
		arm64v[0-9]*)
			[[ "$architecture" =~ ^arm64v([0-9]+)$ ]] || return 1
			printf 'linux/arm64/v%s\n' "${BASH_REMATCH[1]}"
			;;
		unknown|*[!a-z0-9._-]*|'')
			return 1
			;;
		*)
			printf 'linux/%s\n' "$architecture"
			;;
	esac
}

official_tag_platforms() {
	local tag="$1"
	local architectures
	local architecture
	local platform
	local status
	local index
	local -a declared_architectures=()
	local -a platforms=()
	local -a sorted_platforms=()

	architectures="$({
		awk -v wanted="$tag" '
			BEGIN { RS = ""; FS = "\n"; matches = 0 }
			{
				tags = ""
				architectures = ""
				for (line_number = 1; line_number <= NF; line_number++) {
					if ($line_number ~ /^Tags:[[:space:]]*/) {
						tags = $line_number
						sub(/^Tags:[[:space:]]*/, "", tags)
					} else if ($line_number ~ /^Architectures:[[:space:]]*/) {
						architectures = $line_number
						sub(/^Architectures:[[:space:]]*/, "", architectures)
					}
				}

				tag_count = split(tags, tag_values, /[[:space:]]*,[[:space:]]*/)
				for (tag_index = 1; tag_index <= tag_count; tag_index++) {
					if (tag_values[tag_index] == wanted) {
						matches++
						match_architectures = architectures
					}
				}
			}
			END {
				if (matches == 0) exit 1
				if (matches != 1 || match_architectures == "") exit 2
				print match_architectures
			}
		' "$OFFICIAL_IMAGES_SOURCE"
	} 2>/dev/null)" || {
		status=$?
		return "$status"
	}

	IFS=',' read -r -a declared_architectures <<< "$architectures"
	for architecture in "${declared_architectures[@]}"; do
		architecture="${architecture#"${architecture%%[![:space:]]*}"}"
		architecture="${architecture%"${architecture##*[![:space:]]}"}"
		if ! platform="$(normalize_official_architecture "$architecture")"; then
			echo "[ERROR] Unknown official architecture '$architecture' for joomla:$tag" >&2
			return 2
		fi
		platforms+=("$platform")
	done

	[[ "${#platforms[@]}" -gt 0 ]] || return 2
	mapfile -t sorted_platforms < <(printf '%s\n' "${platforms[@]}" | sort)
	for ((index = 1; index < ${#sorted_platforms[@]}; index++)); do
		if [[ "${sorted_platforms[$((index - 1))]}" == "${sorted_platforms[$index]}" ]]; then
			echo "[ERROR] Duplicate canonical platform '${sorted_platforms[$index]}' for joomla:$tag" >&2
			return 2
		fi
	done

	printf '%s\n' "${sorted_platforms[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))'
}

normalize_docker_tag_record() {
	local source="$1"
	local expected_tag="$2"
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
		echo "[ERROR] Docker Hub returned an invalid response for '$expected_tag'" >&2
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
	if ! jq -ce --arg index_digest "$index_digest" '
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
			(if $raw_architecture == "arm" and $raw_variant == "" then
				{architecture: "arm", variant: "v7"}
			elif $raw_architecture == "arm64" and $raw_variant == "" then
				{architecture: "arm64", variant: "v8"}
			elif $raw_architecture == "arm" and $raw_variant == "v8" then
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
		echo "[ERROR] Docker Hub returned conflicting or invalid platforms for '$expected_tag'" >&2
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

docker_api_tag_record() {
	local tag="$1"
	local curl_status=0
	local http_status=""
	local url="${DOCKER_HUB_TAG_API_BASE%/}/${tag}"

	: > "$TAG_TMP"

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
			--output "$TAG_TMP" \
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
		echo "[ERROR] Docker Hub request failed for '$tag' (HTTP ${http_status:-unknown}, curl $curl_status)" >&2
		return 2
	fi

	normalize_docker_tag_record "$TAG_TMP" "$tag"
}

docker_tag_record() {
	local tag="$1"

	if [[ -n "$DOCKER_TAGS_FILE" ]]; then
		docker_fixture_tag_record "$tag"
	else
		docker_api_tag_record "$tag"
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
declare -A PERSISTED_RECORD_BY_TAG=()
declare -A WAITING_MAJOR_SEEN=()
declare -a UPDATED_MAJORS=()
declare -a WAITING_MAJORS=()
declare -a COLLECTED_TAGS=()
declare -a COLLECTED_RECORDS=()

COLLECTION_READY="yes"
STATE_SCHEMA="0"

if [[ -f "$STATE_FILE" ]]; then
	STATE_SCHEMA="$(jq -r '.schema' "$STATE_FILE")"
	if [[ "$STATE_SCHEMA" == "2" ]]; then
		while IFS=$'\t' read -r persisted_tag persisted_record; do
			PERSISTED_RECORD_BY_TAG["$persisted_tag"]="$persisted_record"
		done < <(
			jq -r '.tags | to_entries[] | [.key, (.value | tojson)] | @tsv' "$STATE_FILE"
		)
	fi
fi

mark_major_waiting() {
	local major="$1"

	if [[ -z "${WAITING_MAJOR_SEEN[$major]:-}" ]]; then
		WAITING_MAJOR_SEEN["$major"]=1
		WAITING_MAJORS+=("$major")
	fi
}

platform_set_difference() {
	local minuend="$1"
	local subtrahend="$2"

	jq -cnr \
		--argjson minuend "$minuend" \
		--argjson subtrahend "$subtrahend" \
		'$minuend - $subtrahend | join(",")'
}

collect_matrix_records() {
	local major="$1"
	local version="$2"
	local role="$3"
	local php_version
	local variant
	local tag
	local record
	local required_platforms
	local actual_platforms
	local missing_platforms
	local unexpected_platforms
	local metadata_status
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

			if required_platforms="$(official_tag_platforms "$tag")"; then
				:
			else
				metadata_status=$?
				if [[ "$metadata_status" -ne 1 ]]; then
					return 2
				fi

				if [[ "$role" == "candidate" ]]; then
					COLLECTION_READY="no"
					log "Joomla $major: waiting for official-images metadata for joomla:$tag"
					return 0
				fi

				if [[ -n "${PERSISTED_RECORD_BY_TAG[$tag]:-}" ]]; then
					required_platforms="$(
						jq -c '.platforms | keys' <<< "${PERSISTED_RECORD_BY_TAG[$tag]}"
					)"
					log "Joomla $major: using persisted platform policy for legacy tag joomla:$tag"
				elif [[ "$STATE_SCHEMA" == "1" ]]; then
					required_platforms=""
					log "Joomla $major: discovering platforms while migrating legacy tag joomla:$tag"
				else
					echo "[ERROR] No authoritative or persisted platform policy for current tag: joomla:$tag" >&2
					return 2
				fi
			fi

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

			actual_platforms="$(jq -c '.platforms | keys' <<< "$record")"
			if [[ -z "$required_platforms" ]]; then
				required_platforms="$actual_platforms"
			fi

			missing_platforms="$(platform_set_difference "$required_platforms" "$actual_platforms")"
			unexpected_platforms="$(platform_set_difference "$actual_platforms" "$required_platforms")"
			if [[ -n "$missing_platforms" || -n "$unexpected_platforms" ]]; then
				if [[ "$role" == "candidate" ]]; then
					COLLECTION_READY="no"
					log "Joomla $major: waiting for complete platform set on joomla:$tag (missing: ${missing_platforms:-none}; unexpected: ${unexpected_platforms:-none})"
					return 0
				fi

				echo "[ERROR] Current Docker tag platform set does not match policy: joomla:$tag (missing: ${missing_platforms:-none}; unexpected: ${unexpected_platforms:-none})" >&2
				return 2
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

for major in "${MAJORS[@]}"; do
	current_version="$(jq -r --arg major "$major" '.[$major].joomla' "$VERSIONS_FILE")"
	candidate_version=""
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
