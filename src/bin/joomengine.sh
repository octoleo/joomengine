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

show_help() {
	cat <<'EOF'
Usage: joomengine.sh [options]

Options:
  -q, --quiet        Suppress all stdout output (exit code only)
  -n, --dry-run      Generate/review contexts without building or changing hashes
  -f, --force        Force update docker folder/files
      --build-only   Build images locally, do not push
  -h, --help         Show this help and exit

Behavior:
  - Default: build, tag, and push changed image inputs
  - --dry-run: no build, no tag, no push
  - --force: force all docker files to be update
  - --build-only: build + tag, no push
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
	.schema == 1 and
	.repository == "library/joomla" and
	(.tags | type == "object") and
	all(
		.tags | to_entries[];
		(.key | type == "string") and
		(.value | type == "string" and test("^sha256:[a-f0-9]{64}$"))
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
: > "$BUILD_MANIFEST_FILE"

# --------------------------------------------------
# TRANSACTIONAL BUILD STATE
# --------------------------------------------------
touch "$HASHES_FILE"
NEXT_HASHES_FILE="$(mktemp "${HASHES_FILE}.next.XXXXXX")"
trap 'rm -f -- "$NEXT_HASHES_FILE"' EXIT

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

get_base_image_digest() {
	local tag="$1"

	jq -er --arg tag "$tag" '.tags[$tag]' "$UPSTREAM_IMAGES_FILE"
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
				if ! BASE_IMAGE_DIGEST="$(get_base_image_digest "$BASE_IMAGE_TAG")"; then
					echo "[ERROR] Missing verified digest for official Joomla image tag: $BASE_IMAGE_TAG" >&2
					rm -f "$TMP_XML"
					exit 1
				fi

				HASH_RECORD="${VERSION} ${PHP} ${JOOMLA_VERSION} ${VARIANT} ${SHA} ${RELEASE_INPUT_SHA} ${BUILD_INPUT_SHA} ${BASE_IMAGE_DIGEST}"
				BUILD_KEY="${VERSION}|${PHP}|${JOOMLA_VERSION}|${VARIANT}|${SHA}|${RELEASE_INPUT_SHA}|${BUILD_INPUT_SHA}|${BASE_IMAGE_DIGEST}"
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
				export BASE_IMAGE_DIGEST="$BASE_IMAGE_DIGEST"

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
			if ! BASE_IMAGE_DIGEST="$(get_base_image_digest "$BASE_IMAGE_TAG")"; then
				echo "[ERROR] Missing verified digest for official Joomla image tag: $BASE_IMAGE_TAG" >&2
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
				--arg base_image "joomla:${BASE_IMAGE_TAG}@${BASE_IMAGE_DIGEST}" \
				--arg base_digest "$BASE_IMAGE_DIGEST" \
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
					base_digest: $base_digest,
					base_tag: $tags[0],
					tags: $tags
				}' >> "$BUILD_MANIFEST_FILE"

			echo >> "$TAG_LOG_FILE"
		done
	done
done

echo "✅ Tag review written to: $TAG_LOG_FILE"
echo "✅ Build manifest written to: $BUILD_MANIFEST_FILE"

# --------------------------------------------------
# DOCKER AUTH VALIDATION (before build+push)
# --------------------------------------------------
if [[ "$PENDING_BUILD_COUNT" -gt 0 ]] && [[ "$DRY_RUN" == "no" ]]; then
	if ! docker info >/dev/null 2>&1; then
		echo "❌ Docker daemon not reachable" >&2
		exit 1
	fi
fi

# --------------------------------------------------
# PASS 4: BUILD IMAGES FROM MANIFEST (NDJSON + jq)
# --------------------------------------------------
echo
echo "▶ Building Docker images from manifest"

declare -A BUILT_IMAGES=()

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
			.base_digest
		] | join("|")
	'
}

is_pending_build() {
	local line="$1"
	local key

	key="$(manifest_build_key "$line")"
	[[ -n "${PENDING_BUILDS[$key]:-}" ]]
}

build_image() {
	local LINE="$1"

	# Skip empty lines
	[[ -z "$LINE" ]] && return 0

	# Parse required fields
	read -r IMAGE CONTEXT_PATH BASE_TAG < <(
		echo "$LINE" | jq -r '[.image, .context, .base_tag] | @tsv'
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

	if [[ "$DRY_RUN" == "no" ]]; then
		docker build --pull -t "$FULL_BASE_IMAGE" "$FULL_CONTEXT_PATH"

		echo "  ↪ Pushing $FULL_BASE_IMAGE"
		if [[ "$BUILD_ONLY" == "no" ]]; then
			docker push "$FULL_BASE_IMAGE"
		fi
	fi

	BUILT_IMAGES["$FULL_BASE_IMAGE"]=1
}

publish_image_tags() {
	local LINE="$1"
	local -a TAGS=()
	local IMAGE
	local BASE_TAG
	local FULL_BASE_IMAGE
	local TAG
	local FULL_TAG

	read -r IMAGE BASE_TAG < <(
		echo "$LINE" | jq -r '[.image, .base_tag] | @tsv'
	)
	FULL_BASE_IMAGE="${IMAGE}:${BASE_TAG}"

	# --------------------------------------------------
	# Apply rolling/channel tags only after every changed base image succeeded.
	# --------------------------------------------------
	mapfile -t TAGS < <(echo "$LINE" | jq -r '.tags[]')

	for TAG in "${TAGS[@]}"; do
		FULL_TAG="${IMAGE}:${TAG}"

		# Base tag already applied
		[[ "$FULL_TAG" == "$FULL_BASE_IMAGE" ]] && continue

		echo "  ↪ Tagging $FULL_TAG"
		if [[ "$DRY_RUN" == "no" ]]; then
			docker tag "$FULL_BASE_IMAGE" "$FULL_TAG"
			echo "  ↪ Pushing $FULL_TAG"
			if [[ "$BUILD_ONLY" == "no" ]]; then
				docker push "$FULL_TAG"
			fi
		fi
	done
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
# publish aliases only after every pending base image was built successfully
# --------------------------------------------------
while IFS= read -r line || [[ -n "$line" ]]; do
	[[ -z "$line" ]] && continue
	is_pending_build "$line" || continue

	latest=$(echo "$line" | jq -r '.latest')
	[[ "$latest" == "yes" ]] && continue

	publish_image_tags "$line"
done < "$BUILD_MANIFEST_FILE"

while IFS= read -r line || [[ -n "$line" ]]; do
	[[ -z "$line" ]] && continue
	is_pending_build "$line" || continue

	latest=$(echo "$line" | jq -r '.latest')
	[[ "$latest" == "no" ]] && continue

	publish_image_tags "$line"
done < "$BUILD_MANIFEST_FILE"

if [[ "$PENDING_BUILD_COUNT" -eq 0 ]]; then
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

	sort -u "$NEXT_HASHES_FILE" -o "$NEXT_HASHES_FILE"
	chmod 0644 "$NEXT_HASHES_FILE"
	mv "$NEXT_HASHES_FILE" "$HASHES_FILE"
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
