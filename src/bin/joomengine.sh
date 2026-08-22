#!/usr/bin/env bash
set -euo pipefail

# --------------------------------------------------
# REPOSITORY ROOT RESOLUTION
# --------------------------------------------------

# Absolute path to this script (resolves symlinks)
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

# Try Git first (authoritative)
if REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
	:
else
	# Fallback: assume src/bin layout
	REPO_ROOT="$(realpath "$SCRIPT_DIR/../..")"
fi

# --------------------------------------------------
# FLAGS / DEFAULTS
# --------------------------------------------------
QUIET="no"
DRY_RUN="no"
BUILD_ONLY="no"
FORCE_UPDATE="no"
PLATFORMS_SPEC="auto"

show_help() {
	cat <<'EOF'
Usage: joomengine.sh [options]

Options:
  -q, --quiet        Suppress all stdout output (exit code only)
  -n, --dry-run      Generate/review contexts without building or changing hashes
  -f, --force        Force update docker folder/files
      --build-only   Build images locally, do not push
      --platforms    Platforms to build: auto or a comma-separated Linux subset
  -h, --help         Show this help and exit

Behavior:
  - Default: build and push every platform supported by each Joomla base image
  - --dry-run: no build, no tag, no push
  - --force: force all docker files to be update
  - --build-only: build and load one local platform, no push
  - --platforms auto: publish the exact upstream platform set (the default)
  - --build-only --platforms auto: detect and load the local host platform
  - --quiet: suppress stdout (errors still affect exit code)
EOF
}

# --------------------------------------------------
# ARGUMENT PARSING
# --------------------------------------------------
while [[ $# -gt 0 ]]; do
	case "$1" in
		-q|--quiet)
			QUIET="yes"
			shift
			;;
		-n|--dry-run)
			DRY_RUN="yes"
			shift
			;;
		-f|--force)
			FORCE_UPDATE="yes"
			shift
			;;
		--build-only)
			BUILD_ONLY="yes"
			shift
			;;
		--platforms)
			if [[ $# -lt 2 ]]; then
				echo "❌ --platforms requires auto or a comma-separated Linux platform list" >&2
				exit 1
			fi
			PLATFORMS_SPEC="$2"
			shift 2
			;;
		--platforms=*)
			PLATFORMS_SPEC="${1#*=}"
			shift
			;;
		-h|--help)
			show_help
			exit 0
			;;
		*)
			echo "❌ Unknown option: $1" >&2
			show_help >&2
			exit 1
			;;
	esac
done

validate_platform_name() {
	local platform="$1"

	[[ "$platform" =~ ^linux/[a-z0-9][a-z0-9._-]*(/[a-z0-9][a-z0-9._-]*)?$ ]]
}

canonicalize_platform_name() {
	local platform="$1"

	case "$platform" in
		linux/arm64)
			printf '%s\n' 'linux/arm64/v8'
			;;
		linux/arm)
			printf '%s\n' 'linux/arm/v7'
			;;
		linux/amd64/v1)
			printf '%s\n' 'linux/amd64'
			;;
		*)
			printf '%s\n' "$platform"
			;;
	esac
}

validate_platforms_option() {
	local -a requested=()
	local -a canonical_requested=()
	local platform
	local canonical_platform
	declare -A seen=()

	[[ "$PLATFORMS_SPEC" == "auto" ]] && return 0
	[[ -n "$PLATFORMS_SPEC" ]] || {
		echo "❌ --platforms cannot be empty" >&2
		return 1
	}
	[[ "$PLATFORMS_SPEC" != *, ]] || {
		echo "❌ --platforms contains an empty platform" >&2
		return 1
	}

	IFS=',' read -r -a requested <<< "$PLATFORMS_SPEC"
	for platform in "${requested[@]}"; do
		if ! validate_platform_name "$platform"; then
			echo "❌ Invalid platform '$platform'; expected canonical linux/architecture[/variant]" >&2
			return 1
		fi
		canonical_platform="$(canonicalize_platform_name "$platform")"
		if [[ -n "${seen[$canonical_platform]:-}" ]]; then
			echo "❌ Duplicate platform in --platforms after normalization: $platform" >&2
			return 1
		fi
		seen["$canonical_platform"]=1
		canonical_requested+=("$canonical_platform")
	done

	if [[ "$BUILD_ONLY" == "yes" ]] && [[ "${#canonical_requested[@]}" -ne 1 ]]; then
		echo "❌ --build-only can load exactly one explicit platform" >&2
		return 1
	fi

	PLATFORMS_SPEC="$(IFS=,; echo "${canonical_requested[*]}")"
}

validate_platforms_option

# --------------------------------------------------
# QUIET MODE (stdout only)
# --------------------------------------------------
if [[ "$QUIET" == "yes" ]]; then
	exec >/dev/null
fi

# --------------------------------------------------
# Safety check
# --------------------------------------------------
if [[ ! -d "$REPO_ROOT/conf" || ! -d "$REPO_ROOT/src" ]]; then
	echo "[ERROR] Unable to determine repository root"
	echo "Resolved REPO_ROOT=$REPO_ROOT"
	exit 1
fi

# --------------------------------------------------
# CONFIG (repo-root anchored)
# --------------------------------------------------
VERSIONS_JSON_FILE="$REPO_ROOT/conf/versions.json"
MAINTAINERS_JSON_FILE="$REPO_ROOT/conf/maintainers.json"
HASHES_FILE="$REPO_ROOT/conf/hashes.txt"
BUILD_MANIFEST_FILE="$REPO_ROOT/conf/manifest.ndjson"
UPSTREAM_IMAGES_FILE="$REPO_ROOT/conf/upstream-images.json"

# --------------------------------------------------
# Safety check
# --------------------------------------------------
if [[ ! -f "$VERSIONS_JSON_FILE" ]]; then
	echo "[ERROR] Unable to determine versions file path"
	echo "Resolved VERSIONS_JSON_FILE=$VERSIONS_JSON_FILE"
	exit 1
fi

if [[ ! -f "$MAINTAINERS_JSON_FILE" ]]; then
	echo "[ERROR] Unable to determine maintainers file path"
	echo "Resolved MAINTAINERS_JSON_FILE=$MAINTAINERS_JSON_FILE"
	exit 1
fi

if [[ ! -f "$UPSTREAM_IMAGES_FILE" ]]; then
	echo "[ERROR] Unable to determine verified upstream image state" >&2
	echo "Resolved UPSTREAM_IMAGES_FILE=$UPSTREAM_IMAGES_FILE" >&2
	exit 1
fi

DOCKERFILE_TEMPLATE="$REPO_ROOT/src/docker/Dockerfile.template"
DOCKER_ENTRYPOINT="$REPO_ROOT/src/docker/docker-entrypoint.sh"

# --------------------------------------------------
# Safety check
# --------------------------------------------------
if [[ ! -f "$DOCKERFILE_TEMPLATE" ]]; then
	echo "[ERROR] Unable to determine docker template file path"
	echo "Resolved DOCKERFILE_TEMPLATE=$DOCKERFILE_TEMPLATE"
	exit 1
fi

if [[ ! -f "$DOCKER_ENTRYPOINT" ]]; then
	echo "[ERROR] Unable to determine docker entrypoint file path"
	echo "Resolved DOCKER_ENTRYPOINT=$DOCKER_ENTRYPOINT"
	exit 1
fi

IMAGES_PATH="$REPO_ROOT/images"
LOG_PATH="$REPO_ROOT/log"
TAG_LOG_FILE="$LOG_PATH/joomengine-tag.log"

AWK_SCRIPT="$REPO_ROOT/src/docker/.jq-template.awk"
if [ -n "${BASHBREW_SCRIPTS:-}" ]; then
	AWK_SCRIPT="$BASHBREW_SCRIPTS/jq-template.awk"
fi

BASE_XML_URL="https://raw.githubusercontent.com/joomengine/Joomla-Component-Builder/refs/heads"

# --------------------------------------------------
# TOOLING CHECK
# --------------------------------------------------
for cmd in jq curl xmlstarlet gawk grep sort sha256sum find; do
	command -v "$cmd" >/dev/null || {
		echo "Missing required command: $cmd"
		exit 1
	}
done

if [[ -z "${BASHBREW_SCRIPTS:-}" ]] && [[ ! -f "$AWK_SCRIPT" || "$SCRIPT_PATH" -nt "$AWK_SCRIPT" ]]; then
	AWK_TMP="$(mktemp "${AWK_SCRIPT}.download.XXXXXX")"
	trap 'rm -f -- "$AWK_TMP"' EXIT
	curl \
		--fail \
		--silent \
		--show-error \
		--location \
		--retry 3 \
		--connect-timeout 15 \
		--max-time 60 \
		--output "$AWK_TMP" \
		'https://github.com/docker-library/bashbrew/raw/5f0c26381fb7cc78b2d217d58007800bdcfbcfa1/scripts/jq-template.awk'
	mv "$AWK_TMP" "$AWK_SCRIPT"
	trap - EXIT
fi

if ! jq -e '
	type == "object" and
	.schema == 2 and
	.repository == "library/joomla" and
	(.tags | type == "object") and
	all(
		.tags | to_entries[];
		(.key | type == "string") and
		(.value | type == "object") and
		(.value.index_digest | type == "string" and test("^sha256:[a-f0-9]{64}$")) and
		(.value.platforms | type == "object" and length > 0) and
		all(
			.value.platforms | to_entries[];
			(.key | test("^linux/[a-z0-9][a-z0-9._-]*(/[a-z0-9][a-z0-9._-]*)?$")) and
			(.value | type == "string" and test("^sha256:[a-f0-9]{64}$"))
		)
	)
' "$UPSTREAM_IMAGES_FILE" >/dev/null; then
	echo "[ERROR] Invalid upstream image state: $UPSTREAM_IMAGES_FILE" >&2
	exit 1
fi

# --------------------------------------------------
# GENERATED WARNING
# --------------------------------------------------
generated_warning() {
	cat <<-EOH
	#
	# NOTE: THIS DOCKERFILE IS GENERATED VIA "src/bin/joomengine.sh"
	#
	# PLEASE DO NOT EDIT IT DIRECTLY.
	#
	EOH
}

# --------------------------------------------------
# LOAD MAINTAINERS
# --------------------------------------------------
MAINTAINERS="$(
	jq -cr '
		. | map(
			.firstname + " " +
			.lastname + " <" +
			.email + "> (@" +
			.github + ")"
		) | join(", ")
	' "$MAINTAINERS_JSON_FILE"
)"
export MAINTAINERS

# --------------------------------------------------
# MOVE TO WORKING PATH
# --------------------------------------------------
cd "$REPO_ROOT/conf"

# --------------------------------------------------
# INIT FOLDERS
# --------------------------------------------------
mkdir -p "$LOG_PATH"

# --------------------------------------------------
# INIT FILES
# --------------------------------------------------
: > "$TAG_LOG_FILE"

# Preserve the last committed/generated alias topology before regenerating the
# manifest. Alias ownership can change even when no image content changes.
PREVIOUS_BUILD_MANIFEST_FILE="$(mktemp "${BUILD_MANIFEST_FILE}.previous.XXXXXX")"
if [[ -f "$BUILD_MANIFEST_FILE" ]]; then
	cp "$BUILD_MANIFEST_FILE" "$PREVIOUS_BUILD_MANIFEST_FILE"
fi
NEXT_BUILD_MANIFEST_FILE="$(mktemp "${BUILD_MANIFEST_FILE}.next.XXXXXX")"

# --------------------------------------------------
# TRANSACTIONAL BUILD STATE
# --------------------------------------------------
touch "$HASHES_FILE"
NEXT_HASHES_FILE="$(mktemp "${HASHES_FILE}.next.XXXXXX")"
trap 'rm -f -- "$NEXT_HASHES_FILE" "$PREVIOUS_BUILD_MANIFEST_FILE" "$NEXT_BUILD_MANIFEST_FILE"' EXIT
declare -a STORED_ALIAS_TOPOLOGY_LINES=()
mapfile -t STORED_ALIAS_TOPOLOGY_LINES < <(
	awk '$1 == "alias-topology" { print }' "$HASHES_FILE"
)
if [[ "${#STORED_ALIAS_TOPOLOGY_LINES[@]}" -gt 1 ]]; then
	echo "[ERROR] Multiple alias topology records found in $HASHES_FILE" >&2
	exit 1
fi
OLD_ALIAS_TOPOLOGY_SHA=""
if [[ "${#STORED_ALIAS_TOPOLOGY_LINES[@]}" -eq 1 ]]; then
	if [[ ! "${STORED_ALIAS_TOPOLOGY_LINES[0]}" =~ ^alias-topology\ ([a-f0-9]{64})$ ]]; then
		echo "[ERROR] Invalid alias topology record in $HASHES_FILE" >&2
		exit 1
	fi
	OLD_ALIAS_TOPOLOGY_SHA="${BASH_REMATCH[1]}"
fi

# Any change to these inputs changes the generated image even if the upstream
# Joomla and JCB versions remain the same.
BUILD_INPUT_SHA="$(
	for input_file in \
		"$SCRIPT_PATH" \
		"$AWK_SCRIPT" \
		"$DOCKERFILE_TEMPLATE" \
		"$DOCKER_ENTRYPOINT" \
		"$MAINTAINERS_JSON_FILE"; do
		sha256sum "$input_file" | awk '{ print $1 }'
	done \
		| sha256sum \
		| awk '{ print $1 }'
)"

get_base_image_index_digest() {
	local tag="$1"

	jq -er --arg tag "$tag" '.tags[$tag].index_digest' "$UPSTREAM_IMAGES_FILE"
}

get_base_platforms_json() {
	local tag="$1"

	jq -ec --arg tag "$tag" '
		.tags[$tag].platforms |
		to_entries | sort_by(.key) | from_entries
	' "$UPSTREAM_IMAGES_FILE"
}

detect_local_platform() {
	local architecture

	if [[ -n "${DOCKER_DEFAULT_PLATFORM:-}" ]]; then
		if ! validate_platform_name "$DOCKER_DEFAULT_PLATFORM"; then
			echo "[ERROR] Invalid DOCKER_DEFAULT_PLATFORM: $DOCKER_DEFAULT_PLATFORM" >&2
			return 1
		fi
		canonicalize_platform_name "$DOCKER_DEFAULT_PLATFORM"
		return 0
	fi

	architecture="$(uname -m)"
	case "$architecture" in
		x86_64|amd64)
			architecture="amd64"
			;;
		i386|i486|i586|i686|x86)
			architecture="386"
			;;
		aarch64|arm64)
			architecture="arm64/v8"
			;;
		armv5*)
			architecture="arm/v5"
			;;
		armv6*)
			architecture="arm/v6"
			;;
		armv7*)
			architecture="arm/v7"
			;;
		ppc64le|riscv64|s390x)
			;;
		*)
			architecture="${architecture,,}"
			;;
	esac

	printf 'linux/%s\n' "$architecture"
}

select_base_platforms() {
	local tag="$1"
	local platform
	local -a requested=()

	BASE_PLATFORMS_JSON="$(get_base_platforms_json "$tag")" || return 1

	if [[ "$PLATFORMS_SPEC" == "auto" ]]; then
		if [[ "$BUILD_ONLY" == "yes" ]]; then
			requested+=("$(detect_local_platform)")
		else
			mapfile -t requested < <(jq -r 'keys[]' <<< "$BASE_PLATFORMS_JSON")
		fi
	else
		IFS=',' read -r -a requested <<< "$PLATFORMS_SPEC"
	fi

	for platform in "${requested[@]}"; do
		if ! jq -e --arg platform "$platform" 'has($platform)' <<< "$BASE_PLATFORMS_JSON" >/dev/null; then
			echo "[ERROR] Platform $platform is not available for official Joomla image tag: $tag" >&2
			return 1
		fi
	done

	SELECTED_PLATFORMS_CSV="$(IFS=,; echo "${requested[*]}")"
	SELECTED_PLATFORMS_JSON="$(printf '%s\n' "${requested[@]}" | jq -R . | jq -sc .)"
	SELECTED_PLATFORM_DIGESTS_JSON="$(
		jq -cn \
			--argjson available "$BASE_PLATFORMS_JSON" \
			--argjson selected "$SELECTED_PLATFORMS_JSON" \
			'reduce $selected[] as $platform ({}; .[$platform] = $available[$platform])'
	)"
	BASE_PLATFORM_STATE_SHA="$(
		jq -cS . <<< "$BASE_PLATFORMS_JSON" |
			sha256sum |
			awk '{ print $1 }'
	)"
}

# --------------------------------------------------
# VERSION PARSING
# --------------------------------------------------
parse_version() {
	local v="$1"

	V_MAJOR=""
	V_MINOR=""
	V_PATCH=""
	V_PR=""
	V_PR_NUM=""
	V_IS_STABLE="yes"

	local PR_MAX=999999

	if [[ "$v" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-(alpha|beta|rc)([0-9]*))?$ ]]; then
		V_MAJOR="${BASH_REMATCH[1]}"
		V_MINOR="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
		V_PATCH="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"

		if [[ -n "${BASH_REMATCH[5]}" ]]; then
			V_PR="${BASH_REMATCH[5]}"
			V_IS_STABLE="no"
			V_PR_NUM="${BASH_REMATCH[6]:-$PR_MAX}"
		fi
	else
		echo "❌ Unparseable version: $v" >&2
		return 1
	fi
}

ver_max() {
	printf '%s\n%s\n' "${1:-}" "${2:-}" | sort -V | tail -1
}

# --------------------------------------------------
# LOAD MAJORS
# --------------------------------------------------
mapfile -t MAJORS < <(jq -r 'keys[]' "$VERSIONS_JSON_FILE")

# --------------------------------------------------
# PASS 1: CONTEXT GENERATION + RELEASE COLLECTION
# --------------------------------------------------
declare -a REL_MAJOR REL_VERSION REL_URL REL_TAG REL_SHA REL_INPUT_SHA REL_JOOMLA
declare -A PHP_LIST_BY_MAJOR VARIANT_LIST_BY_MAJOR HIGHEST_PHP_BY_MAJOR PROCESSED_MAJORS
declare -A PENDING_BUILDS
PENDING_BUILD_COUNT=0

for MAJOR in "${MAJORS[@]}"; do
	echo
	echo "▶ Processing major $MAJOR"

	XML_URL="${BASE_XML_URL}/${MAJOR}.x/componentbuilder_update_server.xml"
	TMP_XML="$(mktemp)"

	if ! curl \
		--fail \
		--silent \
		--show-error \
		--location \
		--retry 3 \
		--retry-delay 2 \
		--retry-connrefused \
		--connect-timeout 15 \
		--max-time 60 \
		--output "$TMP_XML" \
		"$XML_URL"; then
		echo "❌ Failed to fetch XML for $MAJOR" >&2
		rm -f "$TMP_XML"
		exit 1
	fi

	mapfile -t PHP_VERSIONS < <(jq -r ".\"$MAJOR\".php[]" "$VERSIONS_JSON_FILE")
	mapfile -t VARIANTS < <(jq -r ".\"$MAJOR\".variants[]" "$VERSIONS_JSON_FILE")
	JOOMLA_VERSION="$(jq -r --arg m "$MAJOR" '.[$m].joomla' "$VERSIONS_JSON_FILE")"

	PHP_LIST_BY_MAJOR["$MAJOR"]="${PHP_VERSIONS[*]}"
	VARIANT_LIST_BY_MAJOR["$MAJOR"]="${VARIANTS[*]}"

	for p in "${PHP_VERSIONS[@]}"; do
		HIGHEST_PHP_BY_MAJOR["$MAJOR"]="$(ver_max "${HIGHEST_PHP_BY_MAJOR[$MAJOR]:-}" "$p")"
	done

	mapfile -t RELEASES < <(
		xmlstarlet sel -t -m "/updates/update" \
			-v "version" -o "|" \
			-v "downloads/downloadurl" -o "|" \
			-v "tags/tag" -o "|" \
			-v "sha512" -n \
		"$TMP_XML" | grep "^$MAJOR\."
	)

	if [[ "${#RELEASES[@]}" -eq 0 ]]; then
		echo "❌ No releases found for $MAJOR" >&2
		rm -f "$TMP_XML"
		exit 1
	fi

	for ROW in "${RELEASES[@]}"; do
		IFS='|' read -r VERSION URL TAG SHA <<<"$ROW"

		if [[ -z "$SHA" ]]; then
			echo "❌ Missing SHA for $VERSION in major $MAJOR" >&2
			rm -f "$TMP_XML"
				exit 1
		fi

		RELEASE_INPUT_SHA="$(
			printf '%s\n' "$VERSION" "$URL" "$TAG" "$SHA" |
				sha256sum |
				awk '{ print $1 }'
		)"

		REL_MAJOR+=("$MAJOR")
		REL_VERSION+=("$VERSION")
		REL_URL+=("$URL")
		REL_TAG+=("$TAG")
		REL_SHA+=("$SHA")
		REL_INPUT_SHA+=("$RELEASE_INPUT_SHA")
		REL_JOOMLA+=("$JOOMLA_VERSION")

		for PHP in "${PHP_VERSIONS[@]}"; do
			for VARIANT in "${VARIANTS[@]}"; do
				BASE_IMAGE_TAG="${JOOMLA_VERSION}-php${PHP}-${VARIANT}"
				if ! BASE_IMAGE_INDEX_DIGEST="$(get_base_image_index_digest "$BASE_IMAGE_TAG")"; then
					echo "[ERROR] Missing verified index digest for official Joomla image tag: $BASE_IMAGE_TAG" >&2
					rm -f "$TMP_XML"
					exit 1
				fi
				if ! select_base_platforms "$BASE_IMAGE_TAG"; then
					rm -f "$TMP_XML"
					exit 1
				fi

				HASH_RECORD="${VERSION} ${PHP} ${JOOMLA_VERSION} ${VARIANT} ${SHA} ${RELEASE_INPUT_SHA} ${BUILD_INPUT_SHA} ${BASE_IMAGE_INDEX_DIGEST} ${BASE_PLATFORM_STATE_SHA} ${SELECTED_PLATFORMS_CSV}"
				BUILD_KEY="${VERSION}|${PHP}|${JOOMLA_VERSION}|${VARIANT}|${SHA}|${RELEASE_INPUT_SHA}|${BUILD_INPUT_SHA}|${BASE_IMAGE_INDEX_DIGEST}|${BASE_PLATFORM_STATE_SHA}|${SELECTED_PLATFORMS_CSV}"
				target="jcb${VERSION}/j${JOOMLA_VERSION}/php${PHP}/${VARIANT}"
				target_dir="${IMAGES_PATH}/${target}"

				if [[ "$FORCE_UPDATE" == "no" ]] && \
					grep -Fxq -- "$HASH_RECORD" "$HASHES_FILE" && \
					[[ -f "${target_dir}/Dockerfile" ]] && \
					[[ -f "${target_dir}/docker-entrypoint.sh" ]]; then
					echo "✅ JCB-${VERSION} PHP-${PHP} J-${JOOMLA_VERSION}(${VARIANT}) already built - skipping"
					printf '%s\n' "$HASH_RECORD" >> "$NEXT_HASHES_FILE"
					continue
				fi

				PENDING_BUILDS["$BUILD_KEY"]=1
				PENDING_BUILD_COUNT=$((PENDING_BUILD_COUNT + 1))

				export JCB_VERSION="$VERSION"
				export JCB_DOWNLOAD_URL="$URL"
				export JCB_SHA512="$SHA"
				export JCB_TAG="$TAG"
				export PHP_VERSION="$PHP"
				export VARIANT="$VARIANT"
				export MAJOR_VERSION="$MAJOR"
				export JOOMLA_VERSION="$JOOMLA_VERSION"
				export BASE_IMAGE_INDEX_DIGEST="$BASE_IMAGE_INDEX_DIGEST"

				mkdir -p "$target_dir"

				echo "  -> generating ${target}"

				cp "$DOCKER_ENTRYPOINT" "${target_dir}/docker-entrypoint.sh"
				chmod +x "${target_dir}/docker-entrypoint.sh"

				{
					generated_warning
					gawk -f "${AWK_SCRIPT}" "${DOCKERFILE_TEMPLATE}"
				} > "${target_dir}/Dockerfile"

				printf '%s\n' "$HASH_RECORD" >> "$NEXT_HASHES_FILE"
			done

		done
	done

	PROCESSED_MAJORS["$MAJOR"]=1
	rm -f "$TMP_XML"
done

# --------------------------------------------------
# PASS 2: TAG LEADERS
# --------------------------------------------------
declare -A HIGHEST_STABLE_BY_MAJOR HIGHEST_STABLE_GLOBAL
declare -A HIGHEST_PR_BY_MAJOR HIGHEST_PR_GLOBAL

for i in "${!REL_VERSION[@]}"; do
	parse_version "${REL_VERSION[$i]}" || continue
	if [[ "$V_IS_STABLE" == "yes" ]]; then
		HIGHEST_STABLE_BY_MAJOR["$V_MAJOR"]="$(ver_max "${HIGHEST_STABLE_BY_MAJOR[$V_MAJOR]:-}" "$V_PATCH")"
		HIGHEST_STABLE_GLOBAL[all]="$(ver_max "${HIGHEST_STABLE_GLOBAL[all]:-}" "$V_PATCH")"
	else
		key="$V_MAJOR|$V_PR"
		HIGHEST_PR_BY_MAJOR["$key"]="$(ver_max "${HIGHEST_PR_BY_MAJOR[$key]:-}" "$V_PATCH")"
		HIGHEST_PR_GLOBAL["$V_PR"]="$(ver_max "${HIGHEST_PR_GLOBAL[$V_PR]:-}" "$V_PATCH")"
	fi
done

# --------------------------------------------------
# PASS 3: TAG EMISSION + BUILD MANIFEST
# --------------------------------------------------
IMAGE_NAME="octoleo/joomengine"
EXPECTED_MANIFEST_RECORD_COUNT=0
for manifest_index in "${!REL_MAJOR[@]}"; do
	IFS=' ' read -r -a expected_php_versions <<< "${PHP_LIST_BY_MAJOR[${REL_MAJOR[$manifest_index]}]}"
	IFS=' ' read -r -a expected_variants <<< "${VARIANT_LIST_BY_MAJOR[${REL_MAJOR[$manifest_index]}]}"
	EXPECTED_MANIFEST_RECORD_COUNT=$((
		EXPECTED_MANIFEST_RECORD_COUNT +
		${#expected_php_versions[@]} * ${#expected_variants[@]}
	))
done

emit_tag() {
	printf "  - %s:%s\n" "$IMAGE_NAME" "$1" >> "$TAG_LOG_FILE"
}

for i in "${!REL_VERSION[@]}"; do
	MAJOR="${REL_MAJOR[$i]}"
	VERSION="${REL_VERSION[$i]}"
	JOOMLA_VERSION="${REL_JOOMLA[$i]}"

	parse_version "$VERSION" || continue

	IFS=' ' read -r -a PHP_VERSIONS <<< "${PHP_LIST_BY_MAJOR[$MAJOR]}"
	IFS=' ' read -r -a VARIANTS <<< "${VARIANT_LIST_BY_MAJOR[$MAJOR]}"
	HIGHEST_PHP="${HIGHEST_PHP_BY_MAJOR[$MAJOR]}"

	# Determine leadership status
	IS_HIGHEST_STABLE_MAJOR="no"
	IS_HIGHEST_STABLE_GLOBAL="no"
	if [[ "$V_IS_STABLE" == "yes" ]]; then
		[[ "${HIGHEST_STABLE_BY_MAJOR[$V_MAJOR]:-}" == "$VERSION" ]] && IS_HIGHEST_STABLE_MAJOR="yes"
		[[ "${HIGHEST_STABLE_GLOBAL[all]:-}" == "$VERSION" ]] && IS_HIGHEST_STABLE_GLOBAL="yes"
	fi

	IS_HIGHEST_PRERELEASE_MAJOR="no"
	IS_HIGHEST_PRERELEASE_GLOBAL="no"
	if [[ "$V_IS_STABLE" == "no" ]]; then
		key="${V_MAJOR}|${V_PR}"
		[[ "${HIGHEST_PR_BY_MAJOR[$key]:-}" == "$VERSION" ]] && IS_HIGHEST_PRERELEASE_MAJOR="yes"
		[[ "${HIGHEST_PR_GLOBAL[$V_PR]:-}" == "$VERSION" ]] && IS_HIGHEST_PRERELEASE_GLOBAL="yes"
	fi

	for PHP in "${PHP_VERSIONS[@]}"; do
		for VARIANT in "${VARIANTS[@]}"; do
			declare -A SEEN=()
			IMAGE_TAGS=()

			emit_once() {
				local t="$1"
				if [[ -z "${SEEN[$t]:-}" ]]; then
					SEEN["$t"]=1
					IMAGE_TAGS+=("$t")
					emit_tag "$t"
				fi
			}

			IS_APACHE="no"
			IS_HIGHEST_PHP="no"
			IS_LATEST="no"

			[[ "$VARIANT" == "apache" ]] && IS_APACHE="yes"
			[[ "$PHP" == "$HIGHEST_PHP" ]] && IS_HIGHEST_PHP="yes"

			{
				echo "--------------------------------------------------"
				echo "IMAGE    : $IMAGE_NAME"
				echo "VERSION  : $VERSION"
				echo "MAJOR    : $V_MAJOR"
				echo "MINOR    : $V_MINOR"
				echo "PHP      : $PHP (highest: $HIGHEST_PHP)"
				echo "VARIANT  : $VARIANT"
				echo "JOOMLA   : $JOOMLA_VERSION"
				echo "LEADERS  : stable_major=$IS_HIGHEST_STABLE_MAJOR stable_global=$IS_HIGHEST_STABLE_GLOBAL pr_major=$IS_HIGHEST_PRERELEASE_MAJOR pr_global=$IS_HIGHEST_PRERELEASE_GLOBAL"
				echo "TAGS:"
			} >> "$TAG_LOG_FILE"

			# ---- Base tag (always)
			emit_once "${VERSION}-php${PHP}-${VARIANT}"

			# ---- Apache shorthand
			if [[ "$IS_APACHE" == "yes" ]]; then
				emit_once "${VERSION}-php${PHP}"
			fi

			# ---- Highest PHP shorthand (variant-level + plain)
			if [[ "$IS_HIGHEST_PHP" == "yes" ]]; then
				emit_once "${VERSION}-${VARIANT}"
				if [[ "$IS_APACHE" == "yes" ]]; then
					emit_once "${VERSION}"
				fi
			fi

			# ---- Stable rolling tags (only if highest stable of this major)
			if [[ "$V_IS_STABLE" == "yes" ]] && [[ "$IS_HIGHEST_STABLE_MAJOR" == "yes" ]]; then
				# minor + major with full suffix
				emit_once "${V_MINOR}-php${PHP}-${VARIANT}"
				emit_once "${V_MAJOR}-php${PHP}-${VARIANT}"

				# apache shorthand
				if [[ "$IS_APACHE" == "yes" ]]; then
					emit_once "${V_MINOR}-php${PHP}"
					emit_once "${V_MAJOR}-php${PHP}"
				fi

				# highest php shorthand
				if [[ "$IS_HIGHEST_PHP" == "yes" ]]; then
					emit_once "${V_MINOR}-${VARIANT}"
					emit_once "${V_MAJOR}-${VARIANT}"
					if [[ "$IS_APACHE" == "yes" ]]; then
						emit_once "${V_MINOR}"
						emit_once "${V_MAJOR}"
					fi
				fi
			fi

			# ---- Global latest (only if highest stable globally, apache, highest php)
			if [[ "$V_IS_STABLE" == "yes" ]] && \
			   [[ "$IS_HIGHEST_STABLE_GLOBAL" == "yes" ]] && \
			   [[ "$IS_APACHE" == "yes" ]] && \
			   [[ "$IS_HIGHEST_PHP" == "yes" ]]; then
				emit_once "latest"
				IS_LATEST="yes"
			fi

			# ---- Pre-release rolling tags
			if [[ "$V_IS_STABLE" == "no" ]]; then
				# Major-scoped leader for this pre-release type (numbered rolling tags)
				if [[ "$IS_HIGHEST_PRERELEASE_MAJOR" == "yes" ]]; then
					# Minor/major numbered tags
					emit_once "${V_MINOR}-${V_PR}${V_PR_NUM}-php${PHP}-${VARIANT}"
					emit_once "${V_MAJOR}-${V_PR}${V_PR_NUM}-php${PHP}-${VARIANT}"

					if [[ "$IS_APACHE" == "yes" ]]; then
						emit_once "${V_MINOR}-${V_PR}${V_PR_NUM}-php${PHP}"
						emit_once "${V_MAJOR}-${V_PR}${V_PR_NUM}-php${PHP}"
					fi

					if [[ "$IS_HIGHEST_PHP" == "yes" ]]; then
						emit_once "${V_MINOR}-${V_PR}${V_PR_NUM}-${VARIANT}"
						emit_once "${V_MAJOR}-${V_PR}${V_PR_NUM}-${VARIANT}"
						if [[ "$IS_APACHE" == "yes" ]]; then
							emit_once "${V_MINOR}-${V_PR}${V_PR_NUM}"
							emit_once "${V_MAJOR}-${V_PR}${V_PR_NUM}"
						fi
					fi
				fi

				# Global leader for this pre-release type (channel tags without number)
				if [[ "$IS_HIGHEST_PRERELEASE_GLOBAL" == "yes" ]]; then
					emit_once "${V_MINOR}-${V_PR}-php${PHP}-${VARIANT}"
					emit_once "${V_MAJOR}-${V_PR}-php${PHP}-${VARIANT}"

					if [[ "$IS_APACHE" == "yes" ]]; then
						emit_once "${V_MINOR}-${V_PR}-php${PHP}"
						emit_once "${V_MAJOR}-${V_PR}-php${PHP}"
					fi

					if [[ "$IS_HIGHEST_PHP" == "yes" ]]; then
						emit_once "${V_MINOR}-${V_PR}-${VARIANT}"
						emit_once "${V_MAJOR}-${V_PR}-${VARIANT}"
						if [[ "$IS_APACHE" == "yes" ]]; then
							emit_once "${V_MINOR}-${V_PR}"
							emit_once "${V_MAJOR}-${V_PR}"
						fi
					fi
				fi
			fi

			context_path="jcb${VERSION}/j${JOOMLA_VERSION}/php${PHP}/${VARIANT}"
			BASE_IMAGE_TAG="${JOOMLA_VERSION}-php${PHP}-${VARIANT}"
			if ! BASE_IMAGE_INDEX_DIGEST="$(get_base_image_index_digest "$BASE_IMAGE_TAG")"; then
				echo "[ERROR] Missing verified index digest for official Joomla image tag: $BASE_IMAGE_TAG" >&2
				exit 1
			fi
			if ! select_base_platforms "$BASE_IMAGE_TAG"; then
				exit 1
			fi

			jq -nc \
				--arg image "$IMAGE_NAME" \
				--arg context "$context_path" \
				--arg version "$VERSION" \
				--arg latest "$IS_LATEST" \
				--arg major "$V_MAJOR" \
				--arg minor "$V_MINOR" \
				--arg php "$PHP" \
				--arg variant "$VARIANT" \
				--arg joomla "$JOOMLA_VERSION" \
				--arg jcb_sha "${REL_SHA[$i]}" \
				--arg release_input_sha "${REL_INPUT_SHA[$i]}" \
				--arg build_input_sha "$BUILD_INPUT_SHA" \
				--arg base_image "joomla:${BASE_IMAGE_TAG}@${BASE_IMAGE_INDEX_DIGEST}" \
				--arg base_index_digest "$BASE_IMAGE_INDEX_DIGEST" \
				--arg base_platform_state_sha "$BASE_PLATFORM_STATE_SHA" \
				--argjson base_platforms "$BASE_PLATFORMS_JSON" \
				--argjson platforms "$SELECTED_PLATFORMS_JSON" \
				--argjson platform_digests "$SELECTED_PLATFORM_DIGESTS_JSON" \
				--argjson tags "$(printf '%s\n' "${IMAGE_TAGS[@]}" | jq -R . | jq -s .)" \
				'{
					image: $image,
					context: $context,
					version: $version,
					latest: $latest,
					major: $major,
					minor: $minor,
					php: $php,
					variant: $variant,
					joomla: $joomla,
					jcb_sha: $jcb_sha,
					release_input_sha: $release_input_sha,
					build_input_sha: $build_input_sha,
					base_image: $base_image,
					base_index_digest: $base_index_digest,
					base_platform_state_sha: $base_platform_state_sha,
					base_platforms: $base_platforms,
					platforms: $platforms,
					platform_digests: $platform_digests,
					base_tag: $tags[0],
					tags: $tags
				}' >> "$NEXT_BUILD_MANIFEST_FILE"

			echo >> "$TAG_LOG_FILE"
		done
	done
done

if ! jq -s -e \
	--argjson expected "$EXPECTED_MANIFEST_RECORD_COUNT" \
	'length == $expected and all(.[]; type == "object")' \
	"$NEXT_BUILD_MANIFEST_FILE" >/dev/null; then
	echo "[ERROR] Generated build manifest is incomplete or invalid" >&2
	exit 1
fi
if [[ -f "$BUILD_MANIFEST_FILE" ]]; then
	chmod --reference="$BUILD_MANIFEST_FILE" "$NEXT_BUILD_MANIFEST_FILE"
else
	chmod 0644 "$NEXT_BUILD_MANIFEST_FILE"
fi
mv "$NEXT_BUILD_MANIFEST_FILE" "$BUILD_MANIFEST_FILE"

echo "✅ Tag review written to: $TAG_LOG_FILE"
echo "✅ Build manifest written to: $BUILD_MANIFEST_FILE"

manifest_build_key() {
	local line="$1"

	echo "$line" | jq -r '
		[
			.version,
			.php,
			.joomla,
			.variant,
			.jcb_sha,
			.release_input_sha,
			.build_input_sha,
			.base_index_digest,
			.base_platform_state_sha,
			(.platforms | join(","))
		] | join("|")
	'
}

is_pending_build() {
	local line="$1"
	local key

	key="$(manifest_build_key "$line")"
	[[ -n "${PENDING_BUILDS[$key]:-}" ]]
}

validate_pending_manifest_record() {
	local line="$1"
	local computed_platform_state_sha

	if ! jq -e '
		(.base_index_digest | type == "string" and test("^sha256:[a-f0-9]{64}$")) and
		(.base_platform_state_sha | type == "string" and test("^[a-f0-9]{64}$")) and
		(.base_platforms | type == "object" and length > 0) and
		(.platforms | type == "array" and length > 0) and
		(.platforms | unique | length) == (.platforms | length) and
		(.platform_digests | type == "object") and
		(. as $record |
		all(
			$record.platforms[];
			. as $platform |
			($record.base_platforms[$platform] | type == "string") and
			$record.platform_digests[$platform] == $record.base_platforms[$platform]
		)
		) and
		(.platform_digests | length) == (.platforms | length)
	' <<< "$line" >/dev/null; then
		echo "[ERROR] Invalid platform provenance in pending build manifest record" >&2
		return 1
	fi

	computed_platform_state_sha="$(
		jq -cS '.base_platforms' <<< "$line" |
			sha256sum |
			awk '{ print $1 }'
	)"
	if [[ "$computed_platform_state_sha" != "$(jq -r '.base_platform_state_sha' <<< "$line")" ]]; then
		echo "[ERROR] Platform provenance hash does not match the pending build manifest" >&2
		return 1
	fi

	if [[ "$BUILD_ONLY" == "yes" ]] && \
	   [[ "$(jq -r '.platforms | length' <<< "$line")" -ne 1 ]]; then
		echo "[ERROR] Local build-only records must target exactly one platform" >&2
		return 1
	fi
}

validate_alias_manifest_record() {
	local line="$1"

	jq -e '
		. as $record |
		type == "object" and
		(.image | type == "string" and length > 0) and
		(.base_tag | type == "string" and length > 0) and
		(.tags | type == "array" and length > 0) and
		all(.tags[]; type == "string" and length > 0) and
		(.tags | unique | length) == (.tags | length) and
		(.tags | index($record.base_tag)) != null
	' <<< "$line" >/dev/null
}

declare -A OLD_ALIAS_BASE=()
declare -A NEW_ALIAS_BASE=()
declare -A NEW_ALIAS_RECORD=()
declare -A NEW_BASE_RECORD=()
declare -A PENDING_BASE_IMAGES=()
PENDING_ALIAS_PROMOTION_COUNT=0
NEW_ALIAS_TOPOLOGY_SHA=""
ALIAS_TOPOLOGY_CHANGED="no"

load_previous_alias_topology() {
	local line
	local image
	local base_tag
	local tag
	local full_base_image
	local full_tag

	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ -z "$line" ]] && continue
		if ! validate_alias_manifest_record "$line"; then
			echo "[ERROR] Invalid previous build manifest alias record" >&2
			return 1
		fi

		read -r image base_tag < <(jq -r '[.image, .base_tag] | @tsv' <<< "$line")
		full_base_image="${image}:${base_tag}"
		while IFS= read -r tag; do
			full_tag="${image}:${tag}"
			[[ "$full_tag" == "$full_base_image" ]] && continue
			if [[ -n "${OLD_ALIAS_BASE[$full_tag]:-}" ]] && \
			   [[ "${OLD_ALIAS_BASE[$full_tag]}" != "$full_base_image" ]]; then
				echo "[ERROR] Conflicting previous alias ownership for $full_tag" >&2
				return 1
			fi
			OLD_ALIAS_BASE["$full_tag"]="$full_base_image"
		done < <(jq -r '.tags[]' <<< "$line")
	done < "$PREVIOUS_BUILD_MANIFEST_FILE"
}

load_new_alias_topology() {
	local line
	local image
	local base_tag
	local tag
	local full_base_image
	local full_tag
	local -a sorted_aliases=()

	# First register every immutable base tag so no rolling alias can silently
	# claim another record's immutable name.
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ -z "$line" ]] && continue
		if ! validate_alias_manifest_record "$line" || \
		   ! validate_pending_manifest_record "$line"; then
			echo "[ERROR] Invalid generated build manifest record" >&2
			return 1
		fi
		read -r image base_tag < <(jq -r '[.image, .base_tag] | @tsv' <<< "$line")
		full_base_image="${image}:${base_tag}"
		if [[ -n "${NEW_BASE_RECORD[$full_base_image]:-}" ]] && \
		   [[ "${NEW_BASE_RECORD[$full_base_image]}" != "$line" ]]; then
			echo "[ERROR] Conflicting immutable base ownership for $full_base_image" >&2
			return 1
		fi
		NEW_BASE_RECORD["$full_base_image"]="$line"
		if is_pending_build "$line"; then
			PENDING_BASE_IMAGES["$full_base_image"]=1
		fi
	done < "$BUILD_MANIFEST_FILE"

	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ -z "$line" ]] && continue
		read -r image base_tag < <(jq -r '[.image, .base_tag] | @tsv' <<< "$line")
		full_base_image="${image}:${base_tag}"
		while IFS= read -r tag; do
			full_tag="${image}:${tag}"
			[[ "$full_tag" == "$full_base_image" ]] && continue

			if [[ -n "${NEW_BASE_RECORD[$full_tag]:-}" ]]; then
				echo "[ERROR] Rolling alias conflicts with immutable base tag: $full_tag" >&2
				return 1
			fi
			if [[ -n "${NEW_ALIAS_BASE[$full_tag]:-}" ]] && \
			   [[ "${NEW_ALIAS_BASE[$full_tag]}" != "$full_base_image" ]]; then
				echo "[ERROR] Conflicting generated alias ownership for $full_tag" >&2
				return 1
			fi
			NEW_ALIAS_BASE["$full_tag"]="$full_base_image"
			NEW_ALIAS_RECORD["$full_tag"]="$line"
		done < <(jq -r '.tags[]' <<< "$line")
	done < "$BUILD_MANIFEST_FILE"

	if [[ "${#NEW_ALIAS_BASE[@]}" -gt 0 ]]; then
		mapfile -t sorted_aliases < <(printf '%s\n' "${!NEW_ALIAS_BASE[@]}" | sort)
	fi
	NEW_ALIAS_TOPOLOGY_SHA="$({
		for full_tag in "${sorted_aliases[@]}"; do
			printf '%s\t%s\n' "$full_tag" "${NEW_ALIAS_BASE[$full_tag]}"
		done
	} | sha256sum | awk '{ print $1 }')"

	if [[ "$OLD_ALIAS_TOPOLOGY_SHA" != "$NEW_ALIAS_TOPOLOGY_SHA" ]]; then
		ALIAS_TOPOLOGY_CHANGED="yes"
		PENDING_ALIAS_PROMOTION_COUNT="${#NEW_ALIAS_BASE[@]}"
	else
		for full_tag in "${!NEW_ALIAS_BASE[@]}"; do
			full_base_image="${NEW_ALIAS_BASE[$full_tag]}"
			if [[ -n "${PENDING_BASE_IMAGES[$full_base_image]:-}" ]]; then
				PENDING_ALIAS_PROMOTION_COUNT=$((PENDING_ALIAS_PROMOTION_COUNT + 1))
			fi
		done
	fi
}

builder_platform_key() {
	local platform

	platform="$(canonicalize_platform_name "${1%\*}")"

	case "$platform" in
		linux/arm64/v8)
			printf '%s\n' 'linux/arm64'
			;;
		*)
			printf '%s\n' "$platform"
			;;
	esac
}

builder_supports_platform() {
	local requested="$1"
	local key

	key="$(builder_platform_key "$requested")"
	[[ -n "${BUILDER_PLATFORMS[$key]:-}" ]] && return 0

	# A newer 32-bit ARM worker can execute images targeting older ARM variants.
	case "$requested" in
		linux/arm/v5)
			[[ -n "${BUILDER_PLATFORMS[linux/arm/v6]:-}" || \
			   -n "${BUILDER_PLATFORMS[linux/arm/v7]:-}" ]]
			;;
		linux/arm/v6)
			[[ -n "${BUILDER_PLATFORMS[linux/arm/v7]:-}" ]]
			;;
		*)
			return 1
			;;
	esac
}

preflight_buildx() {
	local inspect_output
	local line
	local platform_list
	local platform
	local key
	local -a missing=()
	declare -gA BUILDER_PLATFORMS=()

	command -v docker >/dev/null || {
		echo "❌ Missing required command: docker" >&2
		return 1
	}
	if ! docker info >/dev/null 2>&1; then
		echo "❌ Docker daemon not reachable" >&2
		return 1
	fi
	if ! docker buildx version >/dev/null 2>&1; then
		echo "❌ Docker Buildx is not available" >&2
		return 1
	fi
	if ! inspect_output="$(docker buildx inspect --bootstrap 2>&1)"; then
		echo "❌ Unable to inspect or bootstrap the active Buildx builder" >&2
		printf '%s\n' "$inspect_output" >&2
		return 1
	fi

	while IFS= read -r line; do
		[[ "$line" == *Platforms:* ]] || continue
		platform_list="${line#*Platforms:}"
		platform_list="${platform_list//,/ }"
		for platform in $platform_list; do
			key="$(builder_platform_key "$platform")"
			validate_platform_name "$key" || continue
			BUILDER_PLATFORMS["$key"]=1
		done
	done <<< "$inspect_output"

	if [[ "${#BUILDER_PLATFORMS[@]}" -eq 0 ]]; then
		echo "❌ The active Buildx builder did not report any Linux platforms" >&2
		return 1
	fi

	for platform in "${!REQUIRED_BUILDER_PLATFORMS[@]}"; do
		builder_supports_platform "$platform" || missing+=("$platform")
	done

	if [[ "${#missing[@]}" -gt 0 ]]; then
		mapfile -t missing < <(printf '%s\n' "${missing[@]}" | sort)
		echo "❌ Active Buildx builder does not support required platform(s): $(IFS=,; echo "${missing[*]}")" >&2
		return 1
	fi
}

# --------------------------------------------------
# VALIDATE THE COMPLETE PENDING BATCH BEFORE ANY BUILD OR PUSH
# --------------------------------------------------
declare -A REQUIRED_BUILDER_PLATFORMS=()

load_previous_alias_topology || exit 1
load_new_alias_topology || exit 1

while IFS= read -r line || [[ -n "$line" ]]; do
	[[ -z "$line" ]] && continue
	is_pending_build "$line" || continue
	validate_pending_manifest_record "$line" || exit 1
	while IFS= read -r platform; do
		REQUIRED_BUILDER_PLATFORMS["$platform"]=1
	done < <(jq -r '.platforms[]' <<< "$line")
done < "$BUILD_MANIFEST_FILE"

NEEDS_DOCKER_PREFLIGHT="no"
if [[ "$PENDING_BUILD_COUNT" -gt 0 ]] || \
   { [[ "$BUILD_ONLY" == "no" ]] && [[ "$PENDING_ALIAS_PROMOTION_COUNT" -gt 0 ]]; }; then
	NEEDS_DOCKER_PREFLIGHT="yes"
fi
if [[ "$DRY_RUN" == "no" ]] && [[ "$NEEDS_DOCKER_PREFLIGHT" == "yes" ]]; then
	preflight_buildx || exit 1
fi

is_sha256_digest() {
	[[ "$1" =~ ^sha256:[a-f0-9]{64}$ ]]
}

resolve_registry_tag_digest() {
	local image_tag="$1"
	local expected_digest="${2:-}"
	local manifest_json=""
	local observed_digest=""
	local retry_delay="${JOOMENGINE_REGISTRY_RETRY_DELAY_SECONDS:-1}"
	local max_attempts=5
	local attempt
	local sleep_seconds

	[[ "$retry_delay" =~ ^[0-9]+$ ]] || retry_delay=1
	REGISTRY_RESOLVED_DIGEST=""

	for ((attempt = 1; attempt <= max_attempts; attempt++)); do
		observed_digest=""
		if manifest_json="$(
			docker buildx imagetools inspect \
				--format '{{json .Manifest}}' \
				"$image_tag" 2>/dev/null
		)"; then
			observed_digest="$(jq -er '.digest' <<< "$manifest_json" 2>/dev/null || true)"
		fi

		if is_sha256_digest "$observed_digest" && \
		   [[ -z "$expected_digest" || "$observed_digest" == "$expected_digest" ]]; then
			REGISTRY_RESOLVED_DIGEST="$observed_digest"
			return 0
		fi

		if [[ "$attempt" -lt "$max_attempts" ]]; then
			sleep_seconds=$((retry_delay * (1 << (attempt - 1))))
			((sleep_seconds > 0)) && sleep "$sleep_seconds"
		fi
	done

	if [[ -n "$expected_digest" ]]; then
		echo "❌ Registry tag did not resolve to the pushed digest: $image_tag" >&2
		echo "  Expected: $expected_digest" >&2
		echo "  Observed: ${observed_digest:-unavailable}" >&2
	else
		echo "❌ Unable to resolve registry digest for $image_tag" >&2
	fi
	return 1
}

normalize_index_platforms() {
	jq -ec '
		def is_attestation_descriptor:
			(.platform | type == "object") and
			.platform.os == "unknown" and
			.platform.architecture == "unknown" and
			.annotations["vnd.docker.reference.type"] == "attestation-manifest";

		def normalized_descriptor_platform:
			if is_attestation_descriptor then
				empty
			elif (.platform | type != "object") then
				error("manifest descriptor has no platform object")
			elif .platform.os != "linux" then
				error("manifest descriptor is not a runnable Linux platform")
			elif (.platform.architecture | type != "string" or length == 0 or . == "unknown") then
				error("manifest descriptor has an invalid architecture")
			else
				.platform |
				(.variant // "") as $variant |
				if .architecture == "arm64" then
					"linux/arm64/\(if $variant == "" then "v8" else $variant end)"
				elif .architecture == "arm" then
					"linux/arm/\(if $variant == "" then "v7" else $variant end)"
				elif .architecture == "amd64" and ($variant == "" or $variant == "v1") then
					"linux/amd64"
				elif $variant != "" then
					"linux/\(.architecture)/\($variant)"
				else
					"linux/\(.architecture)"
				end
			end;

		[
			.manifests[] |
			normalized_descriptor_platform
		] as $platforms |
		($platforms | unique) as $unique_platforms |
		if ($platforms | length) != ($unique_platforms | length) then
			error("duplicate canonical runnable platform descriptors")
		else
			$unique_platforms
		end
	'
}

normalize_single_image_platform() {
	jq -ec '
		if type != "object" then
			error("single-image configuration is not an object")
		elif .os != "linux" then
			error("single-image configuration is not Linux")
		elif (.architecture | type != "string" or length == 0 or . == "unknown") then
			error("single-image configuration has an invalid architecture")
		else . end |
		(.variant // "") as $variant |
		[
			if .architecture == "arm64" then
				"linux/arm64/\(if $variant == "" then "v8" else $variant end)"
			elif .architecture == "arm" then
				"linux/arm/\(if $variant == "" then "v7" else $variant end)"
			elif .architecture == "amd64" and ($variant == "" or $variant == "v1") then
				"linux/amd64"
			elif $variant != "" then
				"linux/\(.architecture)/\($variant)"
			else
				"linux/\(.architecture)"
			end
		]
	'
}

verify_published_platforms() {
	local line="$1"
	local image="$2"
	local expected_platforms
	local actual_platforms=""
	local raw_manifest=""
	local image_metadata=""
	local retry_delay="${JOOMENGINE_REGISTRY_RETRY_DELAY_SECONDS:-1}"
	local attempt
	local sleep_seconds
	local max_attempts=5

	[[ "$retry_delay" =~ ^[0-9]+$ ]] || retry_delay=1
	expected_platforms="$(jq -c '.platforms | sort | unique' <<< "$line")"

	for ((attempt = 1; attempt <= max_attempts; attempt++)); do
		actual_platforms=""
		if raw_manifest="$(
			docker buildx imagetools inspect --raw "$image" 2>/dev/null
		)" && jq -e . <<< "$raw_manifest" >/dev/null 2>&1; then
			if jq -e '.manifests | type == "array"' <<< "$raw_manifest" >/dev/null 2>&1; then
				if ! actual_platforms="$(normalize_index_platforms <<< "$raw_manifest")"; then
					actual_platforms=""
				fi
			else
				# A registry may return a single image manifest when exactly one
				# platform was pushed. Buildx can resolve its image configuration,
				# which carries the missing OS/architecture metadata.
				if image_metadata="$(
					docker buildx imagetools inspect \
						--format '{{json .Image}}' \
						"$image" 2>/dev/null
				)"; then
					if ! actual_platforms="$(normalize_single_image_platform <<< "$image_metadata")"; then
						actual_platforms=""
					fi
				fi
			fi
		fi

		if [[ -n "$actual_platforms" ]] && [[ "$actual_platforms" == "$expected_platforms" ]]; then
			echo "  ↪ Verified registry platforms for $image"
			return 0
		fi

		if [[ "$attempt" -lt "$max_attempts" ]]; then
			sleep_seconds=$((retry_delay * (1 << (attempt - 1))))
			((sleep_seconds > 0)) && sleep "$sleep_seconds"
		fi
	done

	echo "❌ Published platform verification failed for $image" >&2
	echo "  Expected: $expected_platforms" >&2
	echo "  Observed: ${actual_platforms:-unavailable}" >&2
	return 1
}

# --------------------------------------------------
# PASS 4: BUILD IMAGES FROM MANIFEST (NDJSON + jq)
# --------------------------------------------------
echo
echo "▶ Building Docker images from manifest"

declare -A BUILT_IMAGES=()
declare -A VERIFIED_REGISTRY_SOURCE_DIGESTS=()

build_image() {
	local LINE="$1"
	local IMAGE
	local CONTEXT_PATH
	local BASE_TAG
	local PLATFORM_CSV
	local FULL_BASE_IMAGE
	local FULL_CONTEXT_PATH
	local METADATA_FILE=""
	local OUTPUT_DIGEST=""
	local DESCRIPTOR_DIGEST=""
	local -a BUILD_COMMAND=(docker buildx build --pull)

	# Skip empty lines
	[[ -z "$LINE" ]] && return 0

	# Parse required fields
	read -r IMAGE CONTEXT_PATH BASE_TAG PLATFORM_CSV < <(
		echo "$LINE" | jq -r '[.image, .context, .base_tag, (.platforms | join(","))] | @tsv'
	)

	FULL_BASE_IMAGE="${IMAGE}:${BASE_TAG}"
	FULL_CONTEXT_PATH="${IMAGES_PATH}/${CONTEXT_PATH}"

	# --------------------------------------------------
	# SOFT SKIP: Already built earlier in this run
	# --------------------------------------------------
	if [[ -n "${BUILT_IMAGES[$FULL_BASE_IMAGE]:-}" ]]; then
		echo "  ↪ Skipping already-built (this run) $FULL_BASE_IMAGE"
		return 0
	fi

	echo
	echo "--------------------------------------------------"
	echo "▶ Building $FULL_BASE_IMAGE"
	echo "  Context : ${CONTEXT_PATH}"
	echo "  Platforms: ${PLATFORM_CSV}"

	if [[ "$DRY_RUN" == "no" ]]; then
		BUILD_COMMAND+=(--platform "$PLATFORM_CSV")
		BUILD_COMMAND+=(--tag "$FULL_BASE_IMAGE")

		if [[ "$BUILD_ONLY" == "yes" ]]; then
			BUILD_COMMAND+=(--load)
		else
			METADATA_FILE="$(mktemp "${LOG_PATH}/build-metadata.XXXXXX.json")"
			BUILD_COMMAND+=(--metadata-file "$METADATA_FILE")
			BUILD_COMMAND+=(--push)
		fi
		BUILD_COMMAND+=("$FULL_CONTEXT_PATH")
		if ! "${BUILD_COMMAND[@]}"; then
			[[ -z "$METADATA_FILE" ]] || rm -f -- "$METADATA_FILE"
			return 1
		fi

		if [[ "$BUILD_ONLY" == "yes" ]]; then
			echo "  ↪ Loaded $FULL_BASE_IMAGE into the local image store"
		else
			OUTPUT_DIGEST="$(
				jq -er '."containerimage.digest"' "$METADATA_FILE" 2>/dev/null || true
			)"
			DESCRIPTOR_DIGEST="$(
				jq -er '."containerimage.descriptor".digest' "$METADATA_FILE" 2>/dev/null || true
			)"
			rm -f -- "$METADATA_FILE"
			if ! is_sha256_digest "$OUTPUT_DIGEST" || \
			   ! is_sha256_digest "$DESCRIPTOR_DIGEST" || \
			   [[ "$OUTPUT_DIGEST" != "$DESCRIPTOR_DIGEST" ]]; then
				echo "❌ Buildx returned inconsistent image digest metadata for $FULL_BASE_IMAGE" >&2
				echo "  Output digest: ${OUTPUT_DIGEST:-unavailable}" >&2
				echo "  Descriptor digest: ${DESCRIPTOR_DIGEST:-unavailable}" >&2
				return 1
			fi

			echo "  ↪ Pushed multi-platform image $FULL_BASE_IMAGE"
			resolve_registry_tag_digest "$FULL_BASE_IMAGE" "$OUTPUT_DIGEST" || return 1
			verify_published_platforms "$LINE" "${IMAGE}@${OUTPUT_DIGEST}" || return 1
			VERIFIED_REGISTRY_SOURCE_DIGESTS["$FULL_BASE_IMAGE"]="$OUTPUT_DIGEST"
		fi
	fi

	BUILT_IMAGES["$FULL_BASE_IMAGE"]=1
}

ensure_verified_registry_source() {
	local full_base_image="$1"
	local line="$2"
	local image="${full_base_image%:*}"
	local digest="${VERIFIED_REGISTRY_SOURCE_DIGESTS[$full_base_image]:-}"

	if [[ -z "$digest" ]]; then
		resolve_registry_tag_digest "$full_base_image" || return 1
		digest="$REGISTRY_RESOLVED_DIGEST"
		verify_published_platforms "$line" "${image}@${digest}" || return 1
		VERIFIED_REGISTRY_SOURCE_DIGESTS["$full_base_image"]="$digest"
	fi

	REGISTRY_SOURCE_REFERENCE="${image}@${digest}"
}

promote_planned_alias() {
	local full_tag="$1"
	local full_base_image="${NEW_ALIAS_BASE[$full_tag]}"
	local line="${NEW_ALIAS_RECORD[$full_tag]}"

	if [[ "$ALIAS_TOPOLOGY_CHANGED" == "no" ]] && \
	   [[ -z "${BUILT_IMAGES[$full_base_image]:-}" ]]; then
		return 0
	fi
	if [[ "$BUILD_ONLY" == "yes" ]] && [[ -z "${BUILT_IMAGES[$full_base_image]:-}" ]]; then
		return 0
	fi

	echo "  ↪ Promoting $full_tag"
	[[ "$DRY_RUN" == "no" ]] || return 0

	if [[ "$BUILD_ONLY" == "yes" ]]; then
		docker tag "$full_base_image" "$full_tag"
		return 0
	fi

	ensure_verified_registry_source "$full_base_image" "$line" || return 1
	docker buildx imagetools create \
		--tag "$full_tag" \
		"$REGISTRY_SOURCE_REFERENCE"
}

# --------------------------------------------------
# build the all images except the latest image (first)
# --------------------------------------------------
while IFS= read -r line || [[ -n "$line" ]]; do
	[[ -z "$line" ]] && continue
	is_pending_build "$line" || continue

	latest=$(echo "$line" | jq -r '.latest')

	[[ "$latest" == "yes" ]] && continue

	build_image "$line"
done < "$BUILD_MANIFEST_FILE"

# --------------------------------------------------
# build the latest image (last)
# --------------------------------------------------
while IFS= read -r line || [[ -n "$line" ]]; do
	[[ -z "$line" ]] && continue
	is_pending_build "$line" || continue

	latest=$(echo "$line" | jq -r '.latest')

	[[ "$latest" == "no" ]] && continue

	build_image "$line"
done < "$BUILD_MANIFEST_FILE"

# --------------------------------------------------
# Reconcile aliases only after every immutable base build and verification
# succeeded. Topology-only alias changes are promoted without a base rebuild.
# --------------------------------------------------
declare -a PLANNED_ALIASES=()
if [[ "${#NEW_ALIAS_BASE[@]}" -gt 0 ]]; then
	mapfile -t PLANNED_ALIASES < <(printf '%s\n' "${!NEW_ALIAS_BASE[@]}" | sort)
fi

for full_tag in "${PLANNED_ALIASES[@]}"; do
	[[ "$full_tag" == *:latest ]] && continue
	promote_planned_alias "$full_tag"
done
for full_tag in "${PLANNED_ALIASES[@]}"; do
	[[ "$full_tag" == *:latest ]] || continue
	promote_planned_alias "$full_tag"
done

if [[ "$PENDING_BUILD_COUNT" -eq 0 ]] && \
   [[ "$BUILD_ONLY" == "yes" || "$PENDING_ALIAS_PROMOTION_COUNT" -eq 0 ]]; then
	echo "ℹ️  No changed image inputs detected - nothing to build or publish"
fi

if [[ "$DRY_RUN" == "no" ]]; then
	# Generated contexts intentionally track one Joomla base version per JCB
	# major. Prune the previous Joomla-version directory only after the new
	# contexts were built and published successfully.
	for MAJOR in "${MAJORS[@]}"; do
		[[ -n "${PROCESSED_MAJORS[$MAJOR]:-}" ]] || continue
		JOOMLA_VERSION="$(jq -r --arg major "$MAJOR" '.[$major].joomla' "$VERSIONS_JSON_FILE")"

		while IFS= read -r -d '' jcb_dir; do
			current_context="${jcb_dir}/j${JOOMLA_VERSION}"
			[[ -d "$current_context" ]] || continue

			while IFS= read -r -d '' stale_context; do
				case "$stale_context" in
				"$IMAGES_PATH"/jcb*/j*)
					echo "  ↪ Removing stale generated context: ${stale_context#"$REPO_ROOT"/}"
					rm -rf -- "$stale_context"
					;;
				*)
					echo "[ERROR] Refusing to remove unexpected path: $stale_context" >&2
					exit 1
					;;
				esac
			done < <(
				find "$jcb_dir" \
					-mindepth 1 \
					-maxdepth 1 \
					-type d \
					-name 'j*' \
					! -name "j${JOOMLA_VERSION}" \
					-print0
			)
		done < <(
			find "$IMAGES_PATH" \
				-mindepth 1 \
				-maxdepth 1 \
				-type d \
				-name "jcb${MAJOR}.*" \
				-print0
		)
	done

	# Registry alias topology is publication state, so only advance it after
	# every immutable build, verification, and alias promotion has succeeded.
	# Local build-only runs preserve the last known registry topology.
	if [[ "$BUILD_ONLY" == "yes" ]]; then
		if [[ -n "$OLD_ALIAS_TOPOLOGY_SHA" ]]; then
			printf 'alias-topology %s\n' "$OLD_ALIAS_TOPOLOGY_SHA" >> "$NEXT_HASHES_FILE"
		fi
	else
		printf 'alias-topology %s\n' "$NEW_ALIAS_TOPOLOGY_SHA" >> "$NEXT_HASHES_FILE"
	fi

	sort -u "$NEXT_HASHES_FILE" -o "$NEXT_HASHES_FILE"
	chmod 0644 "$NEXT_HASHES_FILE"
	mv "$NEXT_HASHES_FILE" "$HASHES_FILE"
	rm -f -- "$PREVIOUS_BUILD_MANIFEST_FILE"
	trap - EXIT
else
	echo "ℹ️  Build state was not changed during dry-run"
fi

echo
echo "✅ All images built and tagged successfully"

if [[ "$DRY_RUN" == "no" ]] && [[ "$BUILD_ONLY" == "no" ]]; then
	echo "✅ Registry publication complete"
else
	echo "ℹ️  Registry push skipped (dry-run or build-only)"
fi
