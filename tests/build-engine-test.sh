#!/usr/bin/env bash
set -euo pipefail

TEST_PATH="$(realpath "${BASH_SOURCE[0]}")"
TEST_DIR="$(dirname "$TEST_PATH")"
REPO_ROOT="$(realpath "$TEST_DIR/..")"
ENGINE="$REPO_ROOT/src/bin/joomengine.sh"
TEST_TMP="$(mktemp -d)"

cleanup() {
	rm -rf -- "$TEST_TMP"
}
trap cleanup EXIT

fail() {
	echo "not ok - $*" >&2
	exit 1
}

assert_contains() {
	local file="$1"
	local expected="$2"

	grep -Fq -- "$expected" "$file" || fail "$file does not contain: $expected"
}

assert_not_contains() {
	local file="$1"
	local unexpected="$2"

	if grep -Fq -- "$unexpected" "$file"; then
		fail "$file unexpectedly contains: $unexpected"
	fi
}

assert_no_command() {
	local file="$1"
	local command_prefix="$2"

	if awk -v prefix="$command_prefix" 'index($0, prefix) == 1 { found = 1 } END { exit !found }' "$file"; then
		fail "$file unexpectedly invokes: $command_prefix"
	fi
}

assert_command_before() {
	local file="$1"
	local earlier="$2"
	local later="$3"
	local earlier_line
	local later_line

	earlier_line="$(awk -v needle="$earlier" 'index($0, needle) { print NR; exit }' "$file")"
	later_line="$(awk -v needle="$later" 'index($0, needle) { print NR; exit }' "$file")"
	[[ -n "$earlier_line" && -n "$later_line" && "$earlier_line" -lt "$later_line" ]] || \
		fail "$file does not invoke '$earlier' before '$later'"
}

assert_text_contains() {
	local text="$1"
	local expected="$2"

	[[ "$text" == *"$expected"* ]] || fail "text does not contain: $expected"
}

make_stub() {
	local name="$1"
	ln -s "$TEST_PATH" "$CASE_DIR/bin/$name"
}

# All external interfaces used by the build engine are deterministic fixtures.
if [[ "${JOOMENGINE_BUILD_TEST_MOCK:-no}" == "yes" ]]; then
	case "${0##*/}" in
	curl)
		output=""
		url=""
		while [[ $# -gt 0 ]]; do
			case "$1" in
			-o|--output)
				output="$2"
				shift 2
				;;
			*)
				url="$1"
				shift
				;;
			esac
		done
		[[ -n "$output" ]] || exit 2
		if [[ "$url" == *joomengine_mcp_update_server.xml ]]; then
			cp "$JOOMENGINE_MCP_XML_FILE" "$output"
			printf 'fetch\n' >> "$JOOMENGINE_MCP_FETCH_TRACE"
		else
			jcb_major="${url%/componentbuilder_update_server.xml}"
			jcb_major="${jcb_major##*/}"
			printf '<updates jcb-major="%s"/>\n' "${jcb_major%.x}" > "$output"
		fi
		;;
	xmlstarlet)
		if grep -Fq 'pkg_joomengine_mcp' "${!#}"; then
			exec "$JOOMENGINE_REAL_XMLSTARLET" "$@"
		fi
		jcb_url="$(<"$JOOMENGINE_JCB_URL_FILE")"
		jcb_major="$(sed -n 's/.*jcb-major="\([0-9][0-9]*\)".*/\1/p' "${!#}")"
		printf '%s\n' \
			"${jcb_major}.0.0|${jcb_url}|stable|$(printf 'a%.0s' {1..128})"
		;;
	gawk)
		printf 'FROM joomla:%s-php%s-%s@%s\n' \
			"$JOOMLA_VERSION" "$PHP_VERSION" "$VARIANT" "$BASE_IMAGE_INDEX_DIGEST"
		if [[ "$IMAGE_FLAVOR" == "mcp" ]]; then
			jq -r '"ENV MCP_VERSION=" + .version, "ENV MCP_SHA512=" + .sha512' <<< "$IMAGE_MCP_METADATA"
		fi
		;;
	docker)
		printf '%s\n' "$*" >> "$JOOMENGINE_DOCKER_TRACE"
		case "${1:-} ${2:-} ${3:-}" in
		"info  ")
			printf ' Username: fixture-user\n'
			;;
		"buildx version ")
			printf 'github.com/docker/buildx v0.28.0 fixture\n'
			;;
		"buildx inspect --bootstrap")
			printf 'Name: fixture-builder\n'
			printf 'Driver: docker-container\n'
			printf 'Platforms: %s\n' "${JOOMENGINE_BUILDER_PLATFORMS:-linux/amd64*, linux/arm64, linux/arm/v7, linux/386, linux/ppc64le, linux/riscv64, linux/s390x}"
			;;
		"buildx build --pull")
			[[ "${JOOMENGINE_FAIL_DOCKER_BUILD:-no}" != "yes" ]] || exit 1
			metadata_file=""
			while [[ $# -gt 0 ]]; do
				if [[ "$1" == "--metadata-file" ]]; then
					metadata_file="$2"
					break
				fi
				shift
			done
			if [[ -n "$metadata_file" ]]; then
				output_digest="${JOOMENGINE_BUILD_OUTPUT_DIGEST:-sha256:7777777777777777777777777777777777777777777777777777777777777777}"
				descriptor_digest="${JOOMENGINE_BUILD_DESCRIPTOR_DIGEST:-$output_digest}"
				jq -cn \
					--arg output_digest "$output_digest" \
					--arg descriptor_digest "$descriptor_digest" \
					'{
						"containerimage.digest": $output_digest,
						"containerimage.descriptor": {digest: $descriptor_digest}
					}' > "$metadata_file"
			fi
			;;
		"buildx imagetools create")
			[[ "${JOOMENGINE_FAIL_ALIAS_CREATE:-no}" != "yes" ]] || exit 1
			;;
		"buildx imagetools inspect")
			if [[ "${4:-}" == "--raw" ]]; then
				if [[ -n "${JOOMENGINE_INSPECT_SINGLE_PLATFORM:-}" ]]; then
					printf '%s\n' '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json"}'
				else
					jq -cn \
						--arg platforms "${JOOMENGINE_INSPECT_PLATFORMS:-linux/386,linux/amd64,linux/arm/v5,linux/arm64/v8}" \
						--arg malformed_unknown "${JOOMENGINE_INSPECT_MALFORMED_UNKNOWN:-no}" \
						'($platforms | split(",") | map(
							split("/") as $parts |
							{platform: (
								{os: $parts[0], architecture: $parts[1]} +
								(if ($parts | length) > 2 and
								    ($parts[1] != "arm64" or $parts[2] != "v8")
								 then {variant: $parts[2]} else {} end)
							)}
						)) as $runnable |
						{
							schemaVersion: 2,
							mediaType: "application/vnd.oci.image.index.v1+json",
							manifests: ($runnable + [{
								platform: {os: "unknown", architecture: "unknown"},
								annotations: {"vnd.docker.reference.type": "attestation-manifest"}
							}] +
							(if $malformed_unknown == "yes" then [{
								platform: {os: "unknown", architecture: "unknown"}
							}] else [] end))
						}'
				fi
			elif [[ "${4:-}" == "--format" ]] && [[ "${5:-}" == "{{json .Manifest}}" ]]; then
				registry_digest="${JOOMENGINE_REGISTRY_TAG_DIGEST:-${JOOMENGINE_BUILD_OUTPUT_DIGEST:-sha256:7777777777777777777777777777777777777777777777777777777777777777}}"
				jq -cn --arg digest "$registry_digest" '{
					schemaVersion: 2,
					mediaType: "application/vnd.oci.image.index.v1+json",
					digest: $digest,
					manifests: []
				}'
			elif [[ "${4:-}" == "--format" ]] && [[ -n "${JOOMENGINE_INSPECT_SINGLE_PLATFORM:-}" ]]; then
				IFS='/' read -r inspect_os inspect_arch inspect_variant <<< "$JOOMENGINE_INSPECT_SINGLE_PLATFORM"
				jq -cn \
					--arg os "$inspect_os" \
					--arg architecture "$inspect_arch" \
					--arg variant "$inspect_variant" \
					'{os: $os, architecture: $architecture} +
					(if $variant == "" then {} else {variant: $variant} end)'
			else
				exit 2
			fi
			;;
		esac
		;;
	*)
		echo "unexpected build-engine mock command: ${0##*/}" >&2
		exit 2
		;;
	esac
	exit 0
fi

CASE_DIR="$TEST_TMP/repository"
mkdir -p \
	"$CASE_DIR/bin" \
	"$CASE_DIR/bashbrew" \
	"$CASE_DIR/conf" \
	"$CASE_DIR/images/jcb6.0.0/j6.0.0/php8.4/apache" \
	"$CASE_DIR/log" \
	"$CASE_DIR/src/bin" \
	"$CASE_DIR/src/lib" \
	"$CASE_DIR/src/docker"

cp "$ENGINE" "$CASE_DIR/src/bin/joomengine.sh"
cp "$REPO_ROOT/src/lib/mcp-package.sh" "$CASE_DIR/src/lib/mcp-package.sh"
cp "$REPO_ROOT/src/docker/Dockerfile.template" "$CASE_DIR/src/docker/Dockerfile.template"
cp "$REPO_ROOT/src/docker/docker-entrypoint.sh" "$CASE_DIR/src/docker/docker-entrypoint.sh"
cat > "$CASE_DIR/src/bin/check-joomla-releases.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$JOOMENGINE_REFRESH_TRACE"
[[ ! -v GITHUB_OUTPUT ]] || {
	printf 'detector inherited parent GITHUB_OUTPUT\n' >> "$GITHUB_OUTPUT"
	exit 2
}
refresh_current=no
versions_file=""
state_file=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--refresh-current) refresh_current=yes; shift ;;
	--versions-file) versions_file="$2"; shift 2 ;;
	--state-file) state_file="$2"; shift 2 ;;
	*) echo "unexpected refresh argument: $1" >&2; exit 2 ;;
	esac
done
[[ "$refresh_current" == yes && -s "$versions_file" && -n "$state_file" ]] || exit 2
[[ "${JOOMENGINE_REFRESH_MODE:-success}" != failure ]] || exit 1
if [[ "${JOOMENGINE_REFRESH_MODE:-success}" == incomplete ]]; then
	jq '.tags |= with_entries(select(.key | endswith("-fpm") | not))' "$JOOMENGINE_REFRESH_STATE" > "$state_file"
else
	cp "$JOOMENGINE_REFRESH_STATE" "$state_file"
fi
SH
chmod +x "$CASE_DIR/src/bin/check-joomla-releases.sh"
printf '# deterministic jq template fixture\n' > "$CASE_DIR/bashbrew/jq-template.awk"
printf 'obsolete context\n' > "$CASE_DIR/images/jcb6.0.0/j6.0.0/php8.4/apache/obsolete"
printf 'https://example.test/com_componentbuilder.zip\n' > "$CASE_DIR/jcb-url"
printf '[]\n' > "$CASE_DIR/conf/maintainers.json"
printf 'obsolete build record\n' > "$CASE_DIR/conf/hashes.txt"
export JOOMENGINE_MCP_XML_FILE="$CASE_DIR/mcp-update.xml"
export JOOMENGINE_MCP_FETCH_TRACE="$CASE_DIR/mcp-fetch.trace"
export JOOMENGINE_REFRESH_TRACE="$CASE_DIR/refresh.trace"
export JOOMENGINE_REFRESH_STATE="$CASE_DIR/refresh-state.json"
JOOMENGINE_REAL_XMLSTARLET="$(command -v xmlstarlet)"
export JOOMENGINE_REAL_XMLSTARLET

cat > "$JOOMENGINE_MCP_XML_FILE" <<XML
<?xml version="1.0" encoding="utf-8"?>
<updates><update>
  <name>JoomEngine MCP</name><element>pkg_joomengine_mcp</element><type>package</type>
  <version>1.0.1</version><tags><tag>stable</tag></tags>
  <downloads><downloadurl type="full" format="zip">https://example.test/pkg_joomengine_mcp-1.0.1.zip</downloadurl></downloads>
  <sha512>$(printf 'b%.0s' {1..128})</sha512>
  <php_minimum>8.3.0</php_minimum><targetplatform name="joomla" version="6\.[1-9][0-9]*"/>
</update></updates>
XML

cat > "$CASE_DIR/conf/versions.json" <<'JSON'
{
	"6": {
		"php": ["8.4"],
		"joomla": "6.1.3",
		"variants": ["apache"]
	}
}
JSON

cat > "$CASE_DIR/conf/upstream-images.json" <<'JSON'
{
	"schema": 2,
	"repository": "library/joomla",
	"tags": {
		"6.1.3-php8.4-apache": {
			"index_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
			"platforms": {
				"linux/amd64": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
				"linux/arm/v5": "sha256:2222222222222222222222222222222222222222222222222222222222222222",
				"linux/arm64/v8": "sha256:3333333333333333333333333333333333333333333333333333333333333333"
			}
		}
	}
}
JSON

for mock_name in curl xmlstarlet gawk docker; do
	make_stub "$mock_name"
done

TRACE_FILE="$CASE_DIR/docker.trace"
ENGINE_UNDER_TEST="$CASE_DIR/src/bin/joomengine.sh"
PUBLISHED_DIGEST="sha256:7777777777777777777777777777777777777777777777777777777777777777"
PUBLISHED_REFERENCE="octoleo/joomengine@${PUBLISHED_DIGEST}"

set_alias_topology_hash() {
	local topology_sha="$1"
	local next_hashes="$CASE_DIR/conf/hashes.replaced"

	awk -v replacement="alias-topology $topology_sha" '
		$1 == "alias-topology" {
			if (!written) print replacement
			written = 1
			next
		}
		{ print }
		END { if (!written) print replacement }
	' "$CASE_DIR/conf/hashes.txt" > "$next_hashes"
	mv "$next_hashes" "$CASE_DIR/conf/hashes.txt"
}

run_engine_args() {
	: > "$TRACE_FILE"
	: > "$JOOMENGINE_MCP_FETCH_TRACE"
	: > "$JOOMENGINE_REFRESH_TRACE"
	if ! JOOMENGINE_BUILD_TEST_MOCK=yes \
	JOOMENGINE_DOCKER_TRACE="$TRACE_FILE" \
	JOOMENGINE_JCB_URL_FILE="$CASE_DIR/jcb-url" \
	JOOMENGINE_INSPECT_PLATFORMS="${JOOMENGINE_INSPECT_PLATFORMS:-}" \
	JOOMENGINE_INSPECT_SINGLE_PLATFORM="${JOOMENGINE_INSPECT_SINGLE_PLATFORM:-}" \
	JOOMENGINE_INSPECT_MALFORMED_UNKNOWN="${JOOMENGINE_INSPECT_MALFORMED_UNKNOWN:-no}" \
	JOOMENGINE_BUILD_OUTPUT_DIGEST="${JOOMENGINE_BUILD_OUTPUT_DIGEST:-}" \
	JOOMENGINE_BUILD_DESCRIPTOR_DIGEST="${JOOMENGINE_BUILD_DESCRIPTOR_DIGEST:-}" \
	JOOMENGINE_REGISTRY_TAG_DIGEST="${JOOMENGINE_REGISTRY_TAG_DIGEST:-}" \
	JOOMENGINE_FAIL_ALIAS_CREATE="${JOOMENGINE_FAIL_ALIAS_CREATE:-no}" \
	JOOMENGINE_REGISTRY_RETRY_DELAY_SECONDS=0 \
	BASHBREW_SCRIPTS="$CASE_DIR/bashbrew" \
	DOCKER_DEFAULT_PLATFORM="${JOOMENGINE_TEST_DEFAULT_PLATFORM:-linux/amd64}" \
	PATH="$CASE_DIR/bin:$PATH" \
		"$ENGINE_UNDER_TEST" "$@" > "$CASE_DIR/engine.out" 2> "$CASE_DIR/engine.err"; then
		[[ "${JOOMENGINE_EXPECT_FAILURE:-no}" == "yes" ]] || cat "$CASE_DIR/engine.err" >&2
		return 1
	fi
}

run_engine() {
	run_engine_args --build-only
}

run_engine
[[ ! -s "$JOOMENGINE_REFRESH_TRACE" ]] || fail 'complete verified upstream state unnecessarily refreshed'
assert_contains "$TRACE_FILE" 'buildx inspect --bootstrap'
assert_contains "$TRACE_FILE" 'buildx build --pull --platform linux/amd64 --tag octoleo/joomengine:6.0.0-php8.4-apache --load'
assert_contains \
	"$CASE_DIR/images/jcb6.0.0/j6.1.3/php8.4/apache/Dockerfile" \
	'@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
jq -e '
	.base_index_digest == "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and
	.platforms == ["linux/amd64"] and
	.platform_digests == {
		"linux/amd64": "sha256:1111111111111111111111111111111111111111111111111111111111111111"
	} and
	(.base_platforms | keys) == ["linux/amd64", "linux/arm/v5", "linux/arm64/v8"]
' "$CASE_DIR/conf/manifest.ndjson" >/dev/null || fail 'manifest omitted multi-platform provenance'
[[ ! -d "$CASE_DIR/images/jcb6.0.0/j6.0.0" ]] || fail 'stale Joomla context was not pruned'
[[ "$(wc -l < "$CASE_DIR/conf/hashes.txt")" -eq 2 ]] || fail 'current hash state did not retain exactly both image flavors'
[[ "$(wc -l < "$JOOMENGINE_MCP_FETCH_TRACE")" -eq 1 ]] || fail 'MCP metadata was fetched more than once for the batch'
jq -s -e '
	length == 2 and
	(map(.flavor) | sort) == ["mcp", "standard"] and
	([.[] | select(.flavor == "standard")][0] | .mcp == null and .latest == "yes" and .latest_mcp == "no" and all(.tags[]; endswith("-mcp") | not)) and
	([.[] | select(.flavor == "mcp")][0] | .mcp.version == "1.0.1" and .latest == "no" and .latest_mcp == "yes" and all(.tags[]; endswith("-mcp"))) and
	([.[] | .tags[]] | length) == ([.[] | .tags[]] | unique | length) and
	([.[] | select(.flavor == "standard") | .tags[] + "-mcp"] | sort) == ([.[] | select(.flavor == "mcp") | .tags[]] | sort)
' "$CASE_DIR/conf/manifest.ndjson" >/dev/null || fail 'MCP image tags or provenance are missing, duplicated, or mixed into plain images'
assert_not_contains "$CASE_DIR/images/jcb6.0.0/j6.1.3/php8.4/apache/Dockerfile" 'MCP_VERSION'
assert_contains "$CASE_DIR/images/jcb6.0.0/j6.1.3/php8.4/apache-mcp/Dockerfile" 'MCP_VERSION=1.0.1'
echo 'ok - local auto mode loads one host image pinned to the verified index digest'

first_hashes="$(<"$CASE_DIR/conf/hashes.txt")"
run_engine
[[ ! -s "$TRACE_FILE" ]] || fail 'unchanged inputs invoked Docker'
[[ "$(<"$CASE_DIR/conf/hashes.txt")" == "$first_hashes" ]] || fail 'no-op changed hash state'
assert_contains "$CASE_DIR/engine.out" 'No changed image inputs detected'
echo 'ok - unchanged inputs are a true build no-op'

# A manual Joomla bump can precede the release detector committing its matching
# digests. Refresh only that configured matrix before consuming build inputs.
mkdir "$CASE_DIR/before-refresh"
for saved_file in versions.json upstream-images.json hashes.txt manifest.ndjson; do
	cp "$CASE_DIR/conf/$saved_file" "$CASE_DIR/before-refresh/$saved_file"
done
cp -a "$CASE_DIR/images" "$CASE_DIR/before-refresh/images"
jq '."6".joomla = "6.1.4"' "$CASE_DIR/conf/versions.json" > "$CASE_DIR/conf/versions.next"
mv "$CASE_DIR/conf/versions.next" "$CASE_DIR/conf/versions.json"
jq '.tags["6.1.4-php8.4-apache"] = .tags["6.1.3-php8.4-apache"] | del(.tags["6.1.3-php8.4-apache"])' \
	"$CASE_DIR/conf/upstream-images.json" > "$JOOMENGINE_REFRESH_STATE"
printf 'parent-output=preserved\n' > "$CASE_DIR/github-output"
GITHUB_OUTPUT="$CASE_DIR/github-output" run_engine
[[ "$(wc -l < "$JOOMENGINE_REFRESH_TRACE")" -eq 1 ]] || fail 'manual version bump did not refresh exactly once'
assert_contains "$JOOMENGINE_REFRESH_TRACE" "--refresh-current --versions-file $CASE_DIR/conf/versions.json --state-file $CASE_DIR/conf/upstream-images.json"
[[ "$(<"$CASE_DIR/github-output")" == 'parent-output=preserved' ]] || fail 'refresh contaminated the parent workflow outputs'
assert_contains "$TRACE_FILE" 'buildx build --pull'
assert_contains "$CASE_DIR/images/jcb6.0.0/j6.1.4/php8.4/apache/Dockerfile" \
	'FROM joomla:6.1.4-php8.4-apache@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
jq -s -e 'length == 2 and all(.[]; .joomla == "6.1.4")' \
	"$CASE_DIR/conf/manifest.ndjson" >/dev/null || fail 'manual version bump used stale upstream image records'
echo 'ok - manual Joomla bumps refresh verified digests without altering parent workflow outputs'

rm "$CASE_DIR/conf/upstream-images.json"
run_engine
[[ "$(wc -l < "$JOOMENGINE_REFRESH_TRACE")" -eq 1 ]] || fail 'missing upstream state did not bootstrap exactly once'
cmp -s "$JOOMENGINE_REFRESH_STATE" "$CASE_DIR/conf/upstream-images.json" || fail 'bootstrap did not persist the verified upstream state'
[[ ! -s "$TRACE_FILE" ]] || fail 'restoring identical verified digests unnecessarily rebuilt images'
echo 'ok - missing upstream state is bootstrapped before build input selection'

cp "$CASE_DIR/conf/hashes.txt" "$CASE_DIR/before-refresh/refreshed-hashes.txt"
cp "$CASE_DIR/conf/manifest.ndjson" "$CASE_DIR/before-refresh/refreshed-manifest.ndjson"
jq '."6".variants += ["fpm"]' "$CASE_DIR/conf/versions.json" > "$CASE_DIR/conf/versions.next"
mv "$CASE_DIR/conf/versions.next" "$CASE_DIR/conf/versions.json"
jq '.tags["6.1.4-php8.4-fpm"] = .tags["6.1.4-php8.4-apache"]' \
	"$JOOMENGINE_REFRESH_STATE" > "$CASE_DIR/refresh-state.next"
mv "$CASE_DIR/refresh-state.next" "$JOOMENGINE_REFRESH_STATE"
for refresh_mode in failure incomplete; do
	jq 'del(.tags["6.1.4-php8.4-fpm"])' "$JOOMENGINE_REFRESH_STATE" > "$CASE_DIR/conf/upstream-images.json"
	if JOOMENGINE_EXPECT_FAILURE=yes JOOMENGINE_REFRESH_MODE="$refresh_mode" run_engine; then
		fail "$refresh_mode upstream refresh returned success"
	fi
	[[ "$(wc -l < "$JOOMENGINE_REFRESH_TRACE")" -eq 1 ]] || fail "$refresh_mode refresh was not attempted exactly once"
	[[ ! -s "$TRACE_FILE" ]] || fail "$refresh_mode refresh invoked Docker"
	[[ ! -s "$JOOMENGINE_MCP_FETCH_TRACE" ]] || fail "$refresh_mode refresh fetched MCP metadata before validation"
	cmp -s "$CASE_DIR/before-refresh/refreshed-hashes.txt" "$CASE_DIR/conf/hashes.txt" || fail "$refresh_mode refresh changed successful build hashes"
	cmp -s "$CASE_DIR/before-refresh/refreshed-manifest.ndjson" "$CASE_DIR/conf/manifest.ndjson" || fail "$refresh_mode refresh changed the build manifest"
done
echo 'ok - failed or incomplete digest refresh stops before Docker or successful build state changes'

printf '{invalid state\n' > "$CASE_DIR/conf/upstream-images.json"
if JOOMENGINE_EXPECT_FAILURE=yes run_engine; then
	fail 'malformed existing upstream state returned success'
fi
[[ ! -s "$JOOMENGINE_REFRESH_TRACE" ]] || fail 'malformed existing upstream state was silently refreshed'
[[ ! -s "$TRACE_FILE" && ! -s "$JOOMENGINE_MCP_FETCH_TRACE" ]] || fail 'malformed upstream state caused downstream work'
cmp -s "$CASE_DIR/before-refresh/refreshed-hashes.txt" "$CASE_DIR/conf/hashes.txt" || fail 'malformed upstream state changed successful build hashes'
cmp -s "$CASE_DIR/before-refresh/refreshed-manifest.ndjson" "$CASE_DIR/conf/manifest.ndjson" || fail 'malformed upstream state changed the build manifest'
echo 'ok - malformed existing upstream state fails closed before refresh or build work'

for saved_file in versions.json upstream-images.json hashes.txt manifest.ndjson; do
	cp "$CASE_DIR/before-refresh/$saved_file" "$CASE_DIR/conf/$saved_file"
done
rm -rf -- "$CASE_DIR/images"
cp -a "$CASE_DIR/before-refresh/images" "$CASE_DIR/images"

plain_hash="$(awk '$11 == "standard" { print }' "$CASE_DIR/conf/hashes.txt")"
sed -i 's/1\.0\.1/1.0.2/g' "$JOOMENGINE_MCP_XML_FILE"
run_engine
[[ "$(grep -Fc 'buildx build --pull' "$TRACE_FILE")" -eq 1 ]] || fail 'MCP release change rebuilt plain images'
assert_contains "$TRACE_FILE" '--tag octoleo/joomengine:6.0.0-php8.4-apache-mcp --load'
[[ "$(awk '$11 == "standard" { print }' "$CASE_DIR/conf/hashes.txt")" == "$plain_hash" ]] || fail 'MCP release change altered the standard image fingerprint'
echo 'ok - MCP releases rebuild only explicitly suffixed MCP images'

printf '# resolver implementation change\n' >> "$CASE_DIR/src/lib/mcp-package.sh"
run_engine
[[ "$(grep -Fc 'buildx build --pull' "$TRACE_FILE")" -eq 1 ]] || fail 'MCP helper change rebuilt plain images'
assert_contains "$TRACE_FILE" '--tag octoleo/joomengine:6.0.0-php8.4-apache-mcp --load'
[[ "$(awk '$11 == "standard" { print }' "$CASE_DIR/conf/hashes.txt")" == "$plain_hash" ]] || fail 'MCP helper change altered the standard image fingerprint'
echo 'ok - resolver changes invalidate MCP fingerprints without changing plain images'

printf '# entrypoint change\n' >> "$CASE_DIR/src/docker/docker-entrypoint.sh"
run_engine
assert_contains "$TRACE_FILE" 'buildx build --pull'
entrypoint_hashes="$(<"$CASE_DIR/conf/hashes.txt")"
[[ "$entrypoint_hashes" != "$first_hashes" ]] || fail 'entrypoint change did not advance hash state'
echo 'ok - an entrypoint change rebuilds the affected image'

printf 'https://cdn.example.test/com_componentbuilder.zip\n' > "$CASE_DIR/jcb-url"
run_engine
assert_contains "$TRACE_FILE" 'buildx build --pull'
release_hashes="$(<"$CASE_DIR/conf/hashes.txt")"
[[ "$release_hashes" != "$entrypoint_hashes" ]] || fail 'JCB release metadata change did not advance hash state'
echo 'ok - JCB release metadata changes rebuild the affected image'

jq '.tags["6.1.3-php8.4-apache"].index_digest = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
	"$CASE_DIR/conf/upstream-images.json" > "$CASE_DIR/conf/upstream-images.next"
mv "$CASE_DIR/conf/upstream-images.next" "$CASE_DIR/conf/upstream-images.json"
run_engine
assert_contains "$TRACE_FILE" 'buildx build --pull'
index_hashes="$(<"$CASE_DIR/conf/hashes.txt")"
[[ "$index_hashes" != "$release_hashes" ]] || fail 'base index digest change did not advance hash state'
assert_text_contains "$index_hashes" 'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
echo 'ok - upstream index digest drift rebuilds the affected image'

jq '.tags["6.1.3-php8.4-apache"].platforms["linux/amd64"] = "sha256:4444444444444444444444444444444444444444444444444444444444444444"' \
	"$CASE_DIR/conf/upstream-images.json" > "$CASE_DIR/conf/upstream-images.next"
mv "$CASE_DIR/conf/upstream-images.next" "$CASE_DIR/conf/upstream-images.json"
run_engine
assert_contains "$TRACE_FILE" 'buildx build --pull'
child_hashes="$(<"$CASE_DIR/conf/hashes.txt")"
[[ "$child_hashes" != "$index_hashes" ]] || fail 'platform child digest change did not advance hash state'
echo 'ok - platform child digest drift rebuilds the affected image'

jq '.tags["6.1.3-php8.4-apache"].platforms["linux/386"] = "sha256:5555555555555555555555555555555555555555555555555555555555555555"' \
	"$CASE_DIR/conf/upstream-images.json" > "$CASE_DIR/conf/upstream-images.next"
mv "$CASE_DIR/conf/upstream-images.next" "$CASE_DIR/conf/upstream-images.json"
run_engine
assert_contains "$TRACE_FILE" 'buildx build --pull'
platform_hashes="$(<"$CASE_DIR/conf/hashes.txt")"
[[ "$platform_hashes" != "$child_hashes" ]] || fail 'platform list change did not advance hash state'
echo 'ok - upstream platform-set changes rebuild the affected image'

printf '# template dry-run change\n' >> "$CASE_DIR/src/docker/Dockerfile.template"
: > "$TRACE_FILE"
JOOMENGINE_BUILD_TEST_MOCK=yes \
JOOMENGINE_DOCKER_TRACE="$TRACE_FILE" \
JOOMENGINE_JCB_URL_FILE="$CASE_DIR/jcb-url" \
BASHBREW_SCRIPTS="$CASE_DIR/bashbrew" \
DOCKER_DEFAULT_PLATFORM=linux/amd64 \
PATH="$CASE_DIR/bin:$PATH" \
	"$ENGINE_UNDER_TEST" --dry-run > "$CASE_DIR/engine.out" 2> "$CASE_DIR/engine.err"
[[ ! -s "$TRACE_FILE" ]] || fail 'dry-run invoked Docker'
[[ "$(<"$CASE_DIR/conf/hashes.txt")" == "$platform_hashes" ]] || fail 'dry-run committed hash state'
echo 'ok - dry-run does not invoke Docker or commit build state'

: > "$TRACE_FILE"
if JOOMENGINE_BUILD_TEST_MOCK=yes \
	JOOMENGINE_FAIL_DOCKER_BUILD=yes \
JOOMENGINE_DOCKER_TRACE="$TRACE_FILE" \
JOOMENGINE_JCB_URL_FILE="$CASE_DIR/jcb-url" \
BASHBREW_SCRIPTS="$CASE_DIR/bashbrew" \
DOCKER_DEFAULT_PLATFORM=linux/amd64 \
PATH="$CASE_DIR/bin:$PATH" \
		"$ENGINE_UNDER_TEST" --build-only > "$CASE_DIR/engine.out" 2> "$CASE_DIR/engine.err"; then
	fail 'failed Docker build returned success'
fi
assert_contains "$TRACE_FILE" 'buildx build --pull'
assert_no_command "$TRACE_FILE" 'tag '
assert_not_contains "$TRACE_FILE" 'imagetools create'
[[ "$(<"$CASE_DIR/conf/hashes.txt")" == "$platform_hashes" ]] || fail 'failed build committed hash state'
echo 'ok - failed builds never commit hashes or promote aliases'

if JOOMENGINE_EXPECT_FAILURE=yes \
	JOOMENGINE_BUILD_DESCRIPTOR_DIGEST=sha256:8888888888888888888888888888888888888888888888888888888888888888 \
	run_engine_args --force; then
	fail 'inconsistent Buildx output metadata returned success'
fi
assert_contains "$TRACE_FILE" 'buildx build --pull'
assert_not_contains "$TRACE_FILE" 'imagetools inspect --format {{json .Manifest}}'
assert_not_contains "$TRACE_FILE" 'imagetools create'
assert_contains "$CASE_DIR/engine.err" 'inconsistent image digest metadata'
[[ "$(<"$CASE_DIR/conf/hashes.txt")" == "$platform_hashes" ]] || fail 'metadata mismatch committed hash state'
echo 'ok - inconsistent Buildx output digests block registry verification and aliases'

if JOOMENGINE_EXPECT_FAILURE=yes \
	JOOMENGINE_REGISTRY_TAG_DIGEST=sha256:8888888888888888888888888888888888888888888888888888888888888888 \
	run_engine_args --force; then
	fail 'stale same-platform base tag returned success'
fi
assert_contains "$TRACE_FILE" 'buildx build --pull'
[[ "$(grep -Fc 'imagetools inspect --format {{json .Manifest}}' "$TRACE_FILE")" -eq 5 ]] || fail 'tag digest verification was not retried five times'
assert_not_contains "$TRACE_FILE" 'imagetools inspect --raw'
assert_not_contains "$TRACE_FILE" 'imagetools create'
assert_contains "$CASE_DIR/engine.err" 'did not resolve to the pushed digest'
[[ "$(<"$CASE_DIR/conf/hashes.txt")" == "$platform_hashes" ]] || fail 'stale mutable tag committed hash state'
echo 'ok - stale same-platform mutable tags cannot pass exact digest verification'

: > "$TRACE_FILE"
if JOOMENGINE_BUILD_TEST_MOCK=yes \
	JOOMENGINE_BUILDER_PLATFORMS='linux/amd64*' \
	JOOMENGINE_DOCKER_TRACE="$TRACE_FILE" \
	JOOMENGINE_JCB_URL_FILE="$CASE_DIR/jcb-url" \
	BASHBREW_SCRIPTS="$CASE_DIR/bashbrew" \
	PATH="$CASE_DIR/bin:$PATH" \
		"$ENGINE_UNDER_TEST" --force > "$CASE_DIR/engine.out" 2> "$CASE_DIR/engine.err"; then
	fail 'unsupported Buildx platform set returned success'
fi
assert_contains "$TRACE_FILE" 'buildx inspect --bootstrap'
assert_not_contains "$TRACE_FILE" 'buildx build --pull'
assert_not_contains "$TRACE_FILE" 'imagetools create'
assert_contains "$CASE_DIR/engine.err" 'does not support required platform(s)'
[[ "$(<"$CASE_DIR/conf/hashes.txt")" == "$platform_hashes" ]] || fail 'failed preflight committed hash state'
echo 'ok - Buildx capability preflight fails before the first image mutation'

if JOOMENGINE_EXPECT_FAILURE=yes \
	JOOMENGINE_INSPECT_PLATFORMS='linux/386,linux/amd64,linux/arm/v5,linux/arm64/v8,linux/amd64' \
	run_engine_args --force; then
	fail 'duplicate published platform descriptors returned success'
fi
assert_contains "$TRACE_FILE" 'buildx build --pull --platform linux/386,linux/amd64,linux/arm/v5,linux/arm64/v8'
assert_contains "$TRACE_FILE" "buildx imagetools inspect --raw $PUBLISHED_REFERENCE"
assert_not_contains "$TRACE_FILE" 'imagetools create'
assert_no_command "$TRACE_FILE" 'tag '
assert_contains "$CASE_DIR/engine.err" 'Published platform verification failed'
[[ "$(grep -Fc 'buildx imagetools inspect --raw' "$TRACE_FILE")" -eq 5 ]] || fail 'registry visibility retry was not bounded to five attempts'
[[ "$(<"$CASE_DIR/conf/hashes.txt")" == "$platform_hashes" ]] || fail 'duplicate descriptors committed hash state'
echo 'ok - duplicate runnable descriptors block every alias and hash update'

if JOOMENGINE_EXPECT_FAILURE=yes \
	JOOMENGINE_INSPECT_MALFORMED_UNKNOWN=yes \
	run_engine_args --force; then
	fail 'unrecognized unknown/unknown descriptor returned success'
fi
assert_contains "$TRACE_FILE" 'buildx build --pull --platform linux/386,linux/amd64,linux/arm/v5,linux/arm64/v8'
assert_contains "$TRACE_FILE" "buildx imagetools inspect --raw $PUBLISHED_REFERENCE"
assert_not_contains "$TRACE_FILE" 'imagetools create'
assert_contains "$CASE_DIR/engine.err" 'Published platform verification failed'
[[ "$(<"$CASE_DIR/conf/hashes.txt")" == "$platform_hashes" ]] || fail 'malformed descriptor committed hash state'
echo 'ok - only recognized provenance attestation descriptors are ignored'

run_engine_args --force
assert_contains "$TRACE_FILE" 'buildx build --pull --platform linux/386,linux/amd64,linux/arm/v5,linux/arm64/v8 --tag octoleo/joomengine:6.0.0-php8.4-apache --metadata-file'
assert_contains "$TRACE_FILE" 'buildx imagetools inspect --format {{json .Manifest}} octoleo/joomengine:6.0.0-php8.4-apache'
assert_contains "$TRACE_FILE" "buildx imagetools inspect --raw $PUBLISHED_REFERENCE"
assert_contains "$TRACE_FILE" "buildx imagetools create --tag octoleo/joomengine:latest $PUBLISHED_REFERENCE"
assert_no_command "$TRACE_FILE" 'tag '
assert_command_before "$TRACE_FILE" 'buildx build --pull' 'buildx imagetools create'
assert_command_before "$TRACE_FILE" 'imagetools inspect --format {{json .Manifest}}' 'buildx imagetools inspect --raw'
assert_command_before "$TRACE_FILE" 'buildx build --pull' 'buildx imagetools inspect --raw'
assert_command_before "$TRACE_FILE" 'buildx imagetools inspect --raw' 'buildx imagetools create'
assert_command_before "$TRACE_FILE" '--tag octoleo/joomengine:6.0.0-php8.4-apache-mcp --metadata-file' 'buildx imagetools create'
[[ "$(tail -2 "$TRACE_FILE" | sed -n '1p')" == "buildx imagetools create --tag octoleo/joomengine:latest $PUBLISHED_REFERENCE" ]] || fail 'plain latest was not deferred until all other aliases'
[[ "$(tail -1 "$TRACE_FILE")" == "buildx imagetools create --tag octoleo/joomengine:latest-mcp $PUBLISHED_REFERENCE" ]] || fail 'MCP latest was not deferred until all other aliases'
jq -e '
	.platforms == ["linux/386", "linux/amd64", "linux/arm/v5", "linux/arm64/v8"] and
	.platform_digests == .base_platforms
' "$CASE_DIR/conf/manifest.ndjson" >/dev/null || fail 'auto publication did not select the complete upstream set'
published_hashes="$(<"$CASE_DIR/conf/hashes.txt")"
echo 'ok - default publication pushes the exact automatic platform set before manifest aliases'

printf '# explicit subset change\n' >> "$CASE_DIR/src/docker/Dockerfile.template"
JOOMENGINE_INSPECT_PLATFORMS='linux/amd64,linux/arm64/v8' \
	run_engine_args --platforms linux/amd64,linux/arm64/v8
assert_contains "$TRACE_FILE" 'buildx build --pull --platform linux/amd64,linux/arm64/v8 --tag octoleo/joomengine:6.0.0-php8.4-apache --metadata-file'
assert_contains "$TRACE_FILE" "buildx imagetools inspect --raw $PUBLISHED_REFERENCE"
assert_contains "$TRACE_FILE" "buildx imagetools create --tag octoleo/joomengine:latest $PUBLISHED_REFERENCE"
jq -e '
	.platforms == ["linux/amd64", "linux/arm64/v8"] and
	(.platform_digests | keys) == ["linux/amd64", "linux/arm64/v8"]
' "$CASE_DIR/conf/manifest.ndjson" >/dev/null || fail 'explicit publication subset was not recorded'
subset_hashes="$(<"$CASE_DIR/conf/hashes.txt")"
[[ "$subset_hashes" != "$published_hashes" ]] || fail 'explicit platform subset did not alter hash state'
echo 'ok - explicit publication subsets are validated, pushed, and recorded'

jq '.tags["6.1.3-php8.4-apache"].platforms["linux/arm/v7"] = "sha256:6666666666666666666666666666666666666666666666666666666666666666"' \
	"$CASE_DIR/conf/upstream-images.json" > "$CASE_DIR/conf/upstream-images.next"
mv "$CASE_DIR/conf/upstream-images.next" "$CASE_DIR/conf/upstream-images.json"
printf '# single-platform registry change\n' >> "$CASE_DIR/src/docker/Dockerfile.template"
JOOMENGINE_INSPECT_SINGLE_PLATFORM=linux/arm \
	run_engine_args --platforms linux/arm/v7
assert_contains "$TRACE_FILE" 'buildx build --pull --platform linux/arm/v7 --tag octoleo/joomengine:6.0.0-php8.4-apache --metadata-file'
assert_contains "$TRACE_FILE" "buildx imagetools inspect --raw $PUBLISHED_REFERENCE"
assert_contains "$TRACE_FILE" "buildx imagetools inspect --format {{json .Image}} $PUBLISHED_REFERENCE"
assert_contains "$TRACE_FILE" "buildx imagetools create --tag octoleo/joomengine:latest $PUBLISHED_REFERENCE"
single_hashes="$(<"$CASE_DIR/conf/hashes.txt")"
[[ "$single_hashes" != "$subset_hashes" ]] || fail 'single-platform publication did not alter hash state'
echo 'ok - single-manifest publication normalizes implicit ARM v7 configuration'

: > "$TRACE_FILE"
if JOOMENGINE_BUILD_TEST_MOCK=yes \
	JOOMENGINE_DOCKER_TRACE="$TRACE_FILE" \
	JOOMENGINE_JCB_URL_FILE="$CASE_DIR/jcb-url" \
	BASHBREW_SCRIPTS="$CASE_DIR/bashbrew" \
	PATH="$CASE_DIR/bin:$PATH" \
		"$ENGINE_UNDER_TEST" --platforms linux/s390x > "$CASE_DIR/engine.out" 2> "$CASE_DIR/engine.err"; then
	fail 'platform absent from the upstream base returned success'
fi
[[ ! -s "$TRACE_FILE" ]] || fail 'invalid explicit subset invoked Docker'
assert_contains "$CASE_DIR/engine.err" 'Platform linux/s390x is not available'
[[ "$(<"$CASE_DIR/conf/hashes.txt")" == "$single_hashes" ]] || fail 'invalid subset committed hash state'
echo 'ok - an explicit platform must be a subset of every selected base image'

: > "$TRACE_FILE"
if JOOMENGINE_BUILD_TEST_MOCK=yes \
	JOOMENGINE_DOCKER_TRACE="$TRACE_FILE" \
	JOOMENGINE_JCB_URL_FILE="$CASE_DIR/jcb-url" \
	BASHBREW_SCRIPTS="$CASE_DIR/bashbrew" \
	PATH="$CASE_DIR/bin:$PATH" \
		"$ENGINE_UNDER_TEST" --build-only --platforms linux/amd64,linux/arm64/v8 > "$CASE_DIR/engine.out" 2> "$CASE_DIR/engine.err"; then
	fail 'multi-platform local load returned success'
fi
[[ ! -s "$TRACE_FILE" ]] || fail 'invalid local platform list invoked Docker'
assert_contains "$CASE_DIR/engine.err" '--build-only can load exactly one explicit platform'
echo 'ok - local build-only rejects illegal multi-platform loads'

printf '# explicit local platform change\n' >> "$CASE_DIR/src/docker/Dockerfile.template"
run_engine_args --build-only --platforms linux/arm64/v8
assert_contains "$TRACE_FILE" 'buildx build --pull --platform linux/arm64/v8 --tag octoleo/joomengine:6.0.0-php8.4-apache --load'
assert_contains "$TRACE_FILE" 'tag octoleo/joomengine:6.0.0-php8.4-apache octoleo/joomengine:latest'
assert_not_contains "$TRACE_FILE" 'imagetools create'
echo 'ok - explicit local builds load one selected platform and keep aliases local'

JOOMENGINE_TEST_DEFAULT_PLATFORM=linux/arm64 \
	run_engine_args --build-only --force
assert_contains "$TRACE_FILE" 'buildx build --pull --platform linux/arm64/v8 --tag octoleo/joomengine:6.0.0-php8.4-apache --load'
jq -e '.platforms == ["linux/arm64/v8"]' \
	"$CASE_DIR/conf/manifest.ndjson" >/dev/null || fail 'local platform alias was not canonicalized'
echo 'ok - local Docker platform aliases are canonicalized before recording and building'

AUTO_PLATFORMS='linux/386,linux/amd64,linux/arm/v5,linux/arm/v7,linux/arm64/v8'
JOOMENGINE_INSPECT_PLATFORMS="$AUTO_PLATFORMS" \
	run_engine_args --force
topology_hashes="$(<"$CASE_DIR/conf/hashes.txt")"
topology_line="$(awk '$1 == "alias-topology" { print }' "$CASE_DIR/conf/hashes.txt")"
[[ "$topology_line" =~ ^alias-topology\ [a-f0-9]{64}$ ]] || fail 'publication did not record one valid alias topology hash'
[[ "$(grep -c '^alias-topology ' "$CASE_DIR/conf/hashes.txt")" -eq 1 ]] || fail 'publication recorded duplicate alias topology hashes'

build_only_topology_sha="$(printf '9%.0s' {1..64})"
set_alias_topology_hash "$build_only_topology_sha"
run_engine_args --build-only --force
assert_contains "$TRACE_FILE" 'buildx build --pull --platform linux/amd64'
[[ "$(awk '$1 == "alias-topology" { print }' "$CASE_DIR/conf/hashes.txt")" == "alias-topology $build_only_topology_sha" ]] || \
	fail 'build-only replaced the last known registry alias topology'
echo 'ok - build-only preserves registry alias topology state'

# Restore automatic publication state, then simulate a topology-only config
# change by making the committed topology hash stale while image hashes remain
# current. The generated manifest is deliberately allowed to regenerate.
JOOMENGINE_INSPECT_PLATFORMS="$AUTO_PLATFORMS" \
	run_engine_args --force
topology_hashes="$(<"$CASE_DIR/conf/hashes.txt")"
expected_alias_count="$(
	jq -s '[.[] | .base_tag as $base | .tags[] | select(. != $base)] | length' \
		"$CASE_DIR/conf/manifest.ndjson"
)"
[[ "$expected_alias_count" -gt 1 ]] || fail 'topology fixture did not generate multiple aliases'

dry_run_topology_sha="$(printf '8%.0s' {1..64})"
set_alias_topology_hash "$dry_run_topology_sha"
stale_topology_hashes="$(<"$CASE_DIR/conf/hashes.txt")"
JOOMENGINE_INSPECT_PLATFORMS="$AUTO_PLATFORMS" \
	run_engine_args --dry-run
[[ ! -s "$TRACE_FILE" ]] || fail 'topology dry-run invoked Docker'
[[ "$(<"$CASE_DIR/conf/hashes.txt")" == "$stale_topology_hashes" ]] || fail 'topology dry-run committed registry state'

JOOMENGINE_INSPECT_PLATFORMS="$AUTO_PLATFORMS" \
	run_engine_args
assert_not_contains "$TRACE_FILE" 'buildx build --pull'
assert_contains "$TRACE_FILE" 'buildx imagetools inspect --format {{json .Manifest}} octoleo/joomengine:6.0.0-php8.4-apache'
assert_contains "$TRACE_FILE" "buildx imagetools inspect --raw $PUBLISHED_REFERENCE"
assert_contains "$TRACE_FILE" "buildx imagetools create --tag octoleo/joomengine:latest $PUBLISHED_REFERENCE"
[[ "$(grep -Fc 'buildx imagetools create' "$TRACE_FILE")" -eq "$expected_alias_count" ]] || fail 'topology-only retry did not promote every desired alias'
[[ "$(<"$CASE_DIR/conf/hashes.txt")" == "$topology_hashes" ]] || fail 'successful topology reconciliation did not commit registry state'
echo 'ok - dry-run cannot suppress a topology-only registry retry'

failed_topology_sha="$(printf '6%.0s' {1..64})"
set_alias_topology_hash "$failed_topology_sha"
failed_topology_hashes="$(<"$CASE_DIR/conf/hashes.txt")"
if JOOMENGINE_EXPECT_FAILURE=yes \
	JOOMENGINE_FAIL_ALIAS_CREATE=yes \
	JOOMENGINE_INSPECT_PLATFORMS="$AUTO_PLATFORMS" \
	run_engine_args; then
	fail 'failed registry alias promotion returned success'
fi
assert_not_contains "$TRACE_FILE" 'buildx build --pull'
assert_contains "$TRACE_FILE" 'buildx imagetools create'
[[ "$(<"$CASE_DIR/conf/hashes.txt")" == "$failed_topology_hashes" ]] || fail 'failed alias promotion committed registry state'

JOOMENGINE_INSPECT_PLATFORMS="$AUTO_PLATFORMS" \
	run_engine_args
assert_not_contains "$TRACE_FILE" 'buildx build --pull'
[[ "$(grep -Fc 'buildx imagetools create' "$TRACE_FILE")" -eq "$expected_alias_count" ]] || fail 'failed alias promotion suppressed its retry'
[[ "$(<"$CASE_DIR/conf/hashes.txt")" == "$topology_hashes" ]] || fail 'alias retry did not commit reconciled topology state'
echo 'ok - failed alias promotion leaves topology pending for retry'

jq -nc '{
	image: "octoleo/joomengine",
	base_tag: "5.8.8-php8.4-apache",
	tags: ["5.8.8-php8.4-apache", "latest"]
}' >> "$CASE_DIR/conf/manifest.ndjson"
if JOOMENGINE_EXPECT_FAILURE=yes \
	JOOMENGINE_INSPECT_PLATFORMS="$AUTO_PLATFORMS" \
	run_engine_args; then
	fail 'conflicting previous alias ownership returned success'
fi
[[ ! -s "$TRACE_FILE" ]] || fail 'conflicting alias topology invoked Docker'
assert_contains "$CASE_DIR/engine.err" 'Conflicting previous alias ownership'
[[ "$(<"$CASE_DIR/conf/hashes.txt")" == "$topology_hashes" ]] || fail 'alias conflict changed hash state'
echo 'ok - conflicting alias ownership fails before any Docker mutation'

# Generate a mixed compatibility matrix. Only the PHP minimum and Joomla target
# from the update metadata decide which base runtimes receive MCP counterparts.
rm "$CASE_DIR/conf/manifest.ndjson"
jq '."6".php = ["8.2", "8.3", "8.4"] | ."6".variants = ["apache", "fpm", "fpm-alpine"]' \
	"$CASE_DIR/conf/versions.json" > "$CASE_DIR/conf/versions.next"
mv "$CASE_DIR/conf/versions.next" "$CASE_DIR/conf/versions.json"
jq '.tags["6.1.3-php8.4-apache"] as $base |
	.tags = ([ ["8.2", "8.3", "8.4"][] as $php |
		["apache", "fpm", "fpm-alpine"][] as $variant |
		{key: ("6.1.3-php" + $php + "-" + $variant), value: $base} ] | from_entries)' \
	"$CASE_DIR/conf/upstream-images.json" > "$CASE_DIR/conf/upstream-images.next"
mv "$CASE_DIR/conf/upstream-images.next" "$CASE_DIR/conf/upstream-images.json"
matrix_hashes="$(<"$CASE_DIR/conf/hashes.txt")"
run_engine_args --dry-run
[[ ! -s "$TRACE_FILE" ]] || fail 'compatibility dry-run invoked Docker'
[[ "$(<"$CASE_DIR/conf/hashes.txt")" == "$matrix_hashes" ]] || fail 'compatibility dry-run changed published state'
jq -s -e '
	length == 15 and
	([.[] | select(.flavor == "standard")] | length) == 9 and
	([.[] | select(.flavor == "mcp")] | length) == 6 and
	all(.[] | select(.flavor == "mcp"); .php == "8.3" or .php == "8.4") and
	([.[] | select(.flavor == "mcp") | .variant] | unique) == ["apache", "fpm", "fpm-alpine"] and
	([.[] | .tags[]] | length) == ([.[] | .tags[]] | unique | length)
' "$CASE_DIR/conf/manifest.ndjson" >/dev/null || fail 'PHP compatibility or variant suffix generation was incorrect'
[[ "$(wc -l < "$JOOMENGINE_MCP_FETCH_TRACE")" -eq 1 ]] || fail 'matrix fetched MCP once per context instead of once per batch'
echo 'ok - mixed PHP and Apache/FPM variants receive only eligible, uniquely suffixed counterparts'

cp "$CASE_DIR/conf/versions.json" "$CASE_DIR/conf/versions.matrix"
cp "$CASE_DIR/conf/upstream-images.json" "$CASE_DIR/conf/upstream-images.matrix"
jq '."7" = {php: ["8.4"], joomla: "7.1.3", variants: ["apache"]}' \
	"$CASE_DIR/conf/versions.json" > "$CASE_DIR/conf/versions.next"
mv "$CASE_DIR/conf/versions.next" "$CASE_DIR/conf/versions.json"
jq '.tags["7.1.3-php8.4-apache"] = .tags["6.1.3-php8.4-apache"]' \
	"$CASE_DIR/conf/upstream-images.json" > "$CASE_DIR/conf/upstream-images.next"
mv "$CASE_DIR/conf/upstream-images.next" "$CASE_DIR/conf/upstream-images.json"
run_engine_args --dry-run
jq -s -e '
	([.[] | select(.latest == "yes")] | length == 1 and .[0].version == "7.0.0") and
	([.[] | select(.latest_mcp == "yes")] | length == 1 and .[0].version == "6.0.0" and .[0].joomla == "6.1.3")
' "$CASE_DIR/conf/manifest.ndjson" >/dev/null || fail 'MCP latest followed an incompatible standard latest leader'
mv "$CASE_DIR/conf/versions.matrix" "$CASE_DIR/conf/versions.json"
mv "$CASE_DIR/conf/upstream-images.matrix" "$CASE_DIR/conf/upstream-images.json"
echo 'ok - latest-mcp independently tracks the newest compatible stable image'

for incompatible_joomla in 6.0.5 7.1.3 5.4.3; do
	jq --arg joomla "$incompatible_joomla" '."6".joomla = $joomla' \
		"$CASE_DIR/conf/versions.json" > "$CASE_DIR/conf/versions.next"
	mv "$CASE_DIR/conf/versions.next" "$CASE_DIR/conf/versions.json"
	jq --arg joomla "$incompatible_joomla" '.tags |= (to_entries | map(.key |= sub("^[0-9]+\\.[0-9]+\\.[0-9]+"; $joomla)) | from_entries)' \
		"$CASE_DIR/conf/upstream-images.json" > "$CASE_DIR/conf/upstream-images.next"
	mv "$CASE_DIR/conf/upstream-images.next" "$CASE_DIR/conf/upstream-images.json"
	run_engine_args --dry-run
	jq -s -e 'length == 9 and all(.[]; .flavor == "standard" and .mcp == null)' \
		"$CASE_DIR/conf/manifest.ndjson" >/dev/null || fail "MCP was added to incompatible Joomla $incompatible_joomla"
done
echo 'ok - incompatible Joomla targets retain every plain image and receive no MCP counterpart'

sed -i 's#<sha512>[^<]*</sha512>#<sha512></sha512>#' "$JOOMENGINE_MCP_XML_FILE"
if JOOMENGINE_EXPECT_FAILURE=yes run_engine_args --dry-run; then
	fail 'missing MCP checksum returned success'
fi
[[ ! -s "$TRACE_FILE" ]] || fail 'missing MCP checksum invoked Docker'
[[ "$(<"$CASE_DIR/conf/hashes.txt")" == "$matrix_hashes" ]] || fail 'invalid MCP metadata changed successful build state'
echo 'ok - incomplete MCP metadata fails before building or advancing successful state'
