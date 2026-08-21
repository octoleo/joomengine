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
QUIET="no"

JOOMLA_RELEASES_URL="${JOOMLA_RELEASES_URL:-https://downloads.joomla.org/api/v1/latest/cms}"
DOCKER_HUB_TAG_API_BASE="${DOCKER_HUB_TAG_API_BASE:-https://hub.docker.com/v2/namespaces/library/repositories/joomla/tags}"

show_help() {
	cat <<'EOF'
Usage: check-joomla-releases.sh [options]

Options:
      --versions-file PATH     Joomla build matrix to inspect and update
      --state-file PATH        Persist active Linux/amd64 image digests
      --releases-file PATH     Read Joomla release data from a local JSON file
      --docker-tags-file PATH  Read Docker tag data from a local JSON file
  -q, --quiet                  Suppress informational output
  -h, --help                   Show this help and exit

The local data options provide deterministic, network-free execution for tests.
The Docker fixture format is the Docker Hub list response shape: a top-level
"results" array containing tag objects with "name" and "images" fields.

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

for command_name in jq sort realpath mktemp cmp chmod mv; do
	command -v "$command_name" >/dev/null 2>&1 || fail "Missing required command: $command_name"
done

if [[ -z "$RELEASES_FILE" || -z "$DOCKER_TAGS_FILE" ]]; then
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
	type == "object" and
	.schema == 1 and
	.repository == "library/joomla" and
	(.tags | type == "object") and
	all(
		.tags | to_entries[];
		(.key | test("^[0-9]+\\.[0-9]+\\.[0-9]+-php[0-9]+\\.[0-9]+-[a-z0-9][a-z0-9._-]*$")) and
		(.value | type == "string" and test("^sha256:[a-f0-9]{64}$"))
	)
' "$STATE_FILE" >/dev/null; then
	fail "Invalid upstream image state: $STATE_FILE"
fi

RELEASES_TMP=""
TAG_TMP=""
OUTPUT_TMP=""
STATE_TMP=""

cleanup() {
	[[ -z "$RELEASES_TMP" ]] || rm -f -- "$RELEASES_TMP"
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
			(.digest | type == "string" and test("^sha256:[a-f0-9]{64}$"))
		)
	)
' "$DOCKER_TAGS_FILE" >/dev/null; then
	fail "Docker tag fixture does not match the expected schema"
fi

TAG_TMP="$(mktemp)"

docker_fixture_tag_digest() {
	local tag="$1"
	local digest

	if ! digest="$(jq -er --arg tag "$tag" '
		first(
			.results[] |
			select(.name == $tag) |
			.images[]? |
			select(
					.status == "active" and
					.os == "linux" and
					.architecture == "amd64"
			) |
			.digest
		)
	' "$DOCKER_TAGS_FILE")"; then
		return 1
	fi

	printf '%s\n' "$digest"
}

docker_api_tag_digest() {
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

	if ! jq -e '
		type == "object" and
		(.name | type == "string") and
		(.digest | type == "string" and test("^sha256:[a-f0-9]{64}$")) and
		(.images | type == "array") and
		all(
			.images[];
			(.digest | type == "string" and test("^sha256:[a-f0-9]{64}$"))
		)
	' "$TAG_TMP" >/dev/null; then
		echo "[ERROR] Docker Hub returned an invalid response for '$tag'" >&2
		return 2
	fi

	if ! jq -e --arg tag "$tag" '
		.name == $tag and
		any(
			.images[]?;
			.status == "active" and
			.os == "linux" and
			.architecture == "amd64"
		)
	' "$TAG_TMP" >/dev/null; then
		return 1
	fi

	jq -er '
		first(
			.images[]? |
			select(
				.status == "active" and
				.os == "linux" and
				.architecture == "amd64"
			) |
			.digest
		)
	' "$TAG_TMP"
}

docker_tag_digest() {
	local tag="$1"

	if [[ -n "$DOCKER_TAGS_FILE" ]]; then
		docker_fixture_tag_digest "$tag"
	else
		docker_api_tag_digest "$tag"
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
declare -A DESIRED_DIGEST_BY_TAG=()
declare -A WAITING_MAJOR_SEEN=()
declare -a UPDATED_MAJORS=()
declare -a WAITING_MAJORS=()
declare -a COLLECTED_TAGS=()
declare -a COLLECTED_DIGESTS=()

COLLECTION_READY="yes"
COLLECTION_COMPLETE="yes"
STATE_COMPLETE="yes"
EFFECTIVE_MATRIX_READY="yes"

mark_major_waiting() {
	local major="$1"

	if [[ -z "${WAITING_MAJOR_SEEN[$major]:-}" ]]; then
		WAITING_MAJOR_SEEN["$major"]=1
		WAITING_MAJORS+=("$major")
	fi
}

collect_matrix_digests() {
	local major="$1"
	local version="$2"
	local allow_previous="$3"
	local php_version
	local variant
	local tag
	local digest
	local tag_status
	local -a php_versions=()
	local -a variants=()

	COLLECTED_TAGS=()
	COLLECTED_DIGESTS=()
	COLLECTION_READY="yes"
	COLLECTION_COMPLETE="yes"

	mapfile -t php_versions < <(jq -r --arg major "$major" '.[$major].php[]' "$VERSIONS_FILE")
	mapfile -t variants < <(jq -r --arg major "$major" '.[$major].variants[]' "$VERSIONS_FILE")

	for php_version in "${php_versions[@]}"; do
		for variant in "${variants[@]}"; do
			tag="${version}-php${php_version}-${variant}"

			if digest="$(docker_tag_digest "$tag")"; then
				COLLECTED_TAGS+=("$tag")
				COLLECTED_DIGESTS+=("$digest")
				log "Joomla $major: Docker tag ready: joomla:$tag"
				continue
			else
				tag_status=$?
			fi

			if [[ "$tag_status" -ne 1 ]]; then
				return 2
			fi

			COLLECTION_READY="no"
			log "Joomla $major: waiting for official Docker tag joomla:$tag"

			if [[ "$allow_previous" == "yes" ]]; then
				echo "[ERROR] Currently configured Docker tag is unavailable: joomla:$tag" >&2
				return 2
			fi

			COLLECTION_COMPLETE="no"
			return 0
		done
	done
}

add_collected_digests() {
	local index

	for index in "${!COLLECTED_TAGS[@]}"; do
		DESIRED_DIGEST_BY_TAG["${COLLECTED_TAGS[$index]}"]="${COLLECTED_DIGESTS[$index]}"
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

	if [[ -n "$candidate_version" ]]; then
		if ! collect_matrix_digests "$major" "$candidate_version" "no"; then
			fail "Unable to verify the official Joomla $major Docker image matrix"
		fi

		if [[ "$COLLECTION_READY" == "yes" && "$COLLECTION_COMPLETE" == "yes" ]]; then
			NEW_VERSION_BY_MAJOR["$major"]="$candidate_version"
			UPDATED_MAJORS+=("$major")
			add_collected_digests
			log "Joomla $major: ready to advance $current_version -> $candidate_version"
			continue
		fi

		mark_major_waiting "$major"
	fi

	if ! collect_matrix_digests "$major" "$current_version" "yes"; then
		fail "Unable to verify the current Joomla $major Docker image matrix"
	fi

	if [[ "$COLLECTION_READY" == "no" ]]; then
		mark_major_waiting "$major"
		EFFECTIVE_MATRIX_READY="no"
	fi

	if [[ "$COLLECTION_COMPLETE" == "no" ]]; then
		STATE_COMPLETE="no"
	fi

	add_collected_digests
done

VERSIONS_CHANGED="no"
DIGESTS_CHANGED="no"

if [[ "$EFFECTIVE_MATRIX_READY" == "no" || "$STATE_COMPLETE" == "no" ]]; then
	log "At least one configured base image tag is unavailable; leaving version and digest state unchanged"
	NEW_VERSION_BY_MAJOR=()
	UPDATED_MAJORS=()
fi

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

if [[ "$STATE_COMPLETE" == "yes" && "$EFFECTIVE_MATRIX_READY" == "yes" ]]; then
	desired_tags_json='{}'
	if [[ "${#DESIRED_DIGEST_BY_TAG[@]}" -gt 0 ]]; then
		mapfile -t desired_tags < <(printf '%s\n' "${!DESIRED_DIGEST_BY_TAG[@]}" | sort)
		for tag in "${desired_tags[@]}"; do
			desired_tags_json="$(
				jq -cn \
					--argjson current "$desired_tags_json" \
					--arg tag "$tag" \
					--arg digest "${DESIRED_DIGEST_BY_TAG[$tag]}" \
					'$current + {($tag): $digest}'
			)"
		done
	fi

	STATE_TMP="$(mktemp "${STATE_FILE}.tmp.XXXXXX")"
	jq --tab -n \
		--argjson tags "$desired_tags_json" \
		'{schema: 1, repository: "library/joomla", tags: $tags}' \
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
else
	log "Upstream digest state is incomplete; leaving $STATE_FILE unchanged"
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
