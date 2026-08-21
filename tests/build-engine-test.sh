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
		while [[ $# -gt 0 ]]; do
			case "$1" in
			-o|--output)
				output="$2"
				shift 2
				;;
			*)
				shift
				;;
			esac
		done
		[[ -n "$output" ]] || exit 2
		printf '<updates/>\n' > "$output"
		;;
	xmlstarlet)
		jcb_url="$(<"$JOOMENGINE_JCB_URL_FILE")"
		printf '%s\n' \
			"6.0.0|${jcb_url}|stable|$(printf 'a%.0s' {1..128})"
		;;
	gawk)
		printf 'FROM joomla:%s-php%s-%s@%s\n' \
			"$JOOMLA_VERSION" "$PHP_VERSION" "$VARIANT" "$BASE_IMAGE_DIGEST"
		;;
	docker)
		printf '%s\n' "$*" >> "$JOOMENGINE_DOCKER_TRACE"
		case "${1:-}" in
		info)
			printf ' Username: fixture-user\n'
			;;
		build)
			[[ "${JOOMENGINE_FAIL_DOCKER_BUILD:-no}" != "yes" ]]
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
	"$CASE_DIR/src/docker"

cp "$ENGINE" "$CASE_DIR/src/bin/joomengine.sh"
cp "$REPO_ROOT/src/docker/Dockerfile.template" "$CASE_DIR/src/docker/Dockerfile.template"
cp "$REPO_ROOT/src/docker/docker-entrypoint.sh" "$CASE_DIR/src/docker/docker-entrypoint.sh"
printf '# deterministic jq template fixture\n' > "$CASE_DIR/bashbrew/jq-template.awk"
printf 'obsolete context\n' > "$CASE_DIR/images/jcb6.0.0/j6.0.0/php8.4/apache/obsolete"
printf 'https://example.test/com_componentbuilder.zip\n' > "$CASE_DIR/jcb-url"
printf '[]\n' > "$CASE_DIR/conf/maintainers.json"
printf 'obsolete build record\n' > "$CASE_DIR/conf/hashes.txt"

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
	"schema": 1,
	"repository": "library/joomla",
	"tags": {
		"6.1.3-php8.4-apache": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	}
}
JSON

for mock_name in curl xmlstarlet gawk docker; do
	make_stub "$mock_name"
done

TRACE_FILE="$CASE_DIR/docker.trace"
ENGINE_UNDER_TEST="$CASE_DIR/src/bin/joomengine.sh"

run_engine() {
	: > "$TRACE_FILE"
	JOOMENGINE_BUILD_TEST_MOCK=yes \
	JOOMENGINE_DOCKER_TRACE="$TRACE_FILE" \
	JOOMENGINE_JCB_URL_FILE="$CASE_DIR/jcb-url" \
	BASHBREW_SCRIPTS="$CASE_DIR/bashbrew" \
	PATH="$CASE_DIR/bin:$PATH" \
		"$ENGINE_UNDER_TEST" --build-only > "$CASE_DIR/engine.out" 2> "$CASE_DIR/engine.err"
}

run_engine
assert_contains "$TRACE_FILE" 'build --pull -t octoleo/joomengine:6.0.0-php8.4-apache'
assert_contains \
	"$CASE_DIR/images/jcb6.0.0/j6.1.3/php8.4/apache/Dockerfile" \
	'@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
[[ ! -d "$CASE_DIR/images/jcb6.0.0/j6.0.0" ]] || fail 'stale Joomla context was not pruned'
[[ "$(wc -l < "$CASE_DIR/conf/hashes.txt")" -eq 1 ]] || fail 'current hash state was not compact'
echo 'ok - first run builds with a verified base digest and prunes stale context'

first_hashes="$(<"$CASE_DIR/conf/hashes.txt")"
run_engine
[[ ! -s "$TRACE_FILE" ]] || fail 'unchanged inputs invoked Docker'
[[ "$(<"$CASE_DIR/conf/hashes.txt")" == "$first_hashes" ]] || fail 'no-op changed hash state'
assert_contains "$CASE_DIR/engine.out" 'No changed image inputs detected'
echo 'ok - unchanged inputs are a true build no-op'

printf '# entrypoint change\n' >> "$CASE_DIR/src/docker/docker-entrypoint.sh"
run_engine
assert_contains "$TRACE_FILE" 'build --pull'
entrypoint_hashes="$(<"$CASE_DIR/conf/hashes.txt")"
[[ "$entrypoint_hashes" != "$first_hashes" ]] || fail 'entrypoint change did not advance hash state'
echo 'ok - an entrypoint change rebuilds the affected image'

printf 'https://cdn.example.test/com_componentbuilder.zip\n' > "$CASE_DIR/jcb-url"
run_engine
assert_contains "$TRACE_FILE" 'build --pull'
release_hashes="$(<"$CASE_DIR/conf/hashes.txt")"
[[ "$release_hashes" != "$entrypoint_hashes" ]] || fail 'JCB release metadata change did not advance hash state'
echo 'ok - JCB release metadata changes rebuild the affected image'

jq '.tags["6.1.3-php8.4-apache"] = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
	"$CASE_DIR/conf/upstream-images.json" > "$CASE_DIR/conf/upstream-images.next"
mv "$CASE_DIR/conf/upstream-images.next" "$CASE_DIR/conf/upstream-images.json"
run_engine
assert_contains "$TRACE_FILE" 'build --pull'
digest_hashes="$(<"$CASE_DIR/conf/hashes.txt")"
[[ "$digest_hashes" != "$release_hashes" ]] || fail 'base digest change did not advance hash state'
assert_text_contains "$digest_hashes" 'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
echo 'ok - upstream digest drift rebuilds the affected image'

printf '# template dry-run change\n' >> "$CASE_DIR/src/docker/Dockerfile.template"
: > "$TRACE_FILE"
JOOMENGINE_BUILD_TEST_MOCK=yes \
JOOMENGINE_DOCKER_TRACE="$TRACE_FILE" \
JOOMENGINE_JCB_URL_FILE="$CASE_DIR/jcb-url" \
BASHBREW_SCRIPTS="$CASE_DIR/bashbrew" \
PATH="$CASE_DIR/bin:$PATH" \
	"$ENGINE_UNDER_TEST" --dry-run > "$CASE_DIR/engine.out" 2> "$CASE_DIR/engine.err"
[[ ! -s "$TRACE_FILE" ]] || fail 'dry-run invoked Docker'
[[ "$(<"$CASE_DIR/conf/hashes.txt")" == "$digest_hashes" ]] || fail 'dry-run committed hash state'
echo 'ok - dry-run does not invoke Docker or commit build state'

: > "$TRACE_FILE"
if JOOMENGINE_BUILD_TEST_MOCK=yes \
	JOOMENGINE_FAIL_DOCKER_BUILD=yes \
	JOOMENGINE_DOCKER_TRACE="$TRACE_FILE" \
	JOOMENGINE_JCB_URL_FILE="$CASE_DIR/jcb-url" \
	BASHBREW_SCRIPTS="$CASE_DIR/bashbrew" \
	PATH="$CASE_DIR/bin:$PATH" \
		"$ENGINE_UNDER_TEST" --build-only > "$CASE_DIR/engine.out" 2> "$CASE_DIR/engine.err"; then
	fail 'failed Docker build returned success'
fi
assert_contains "$TRACE_FILE" 'build --pull'
assert_not_contains "$TRACE_FILE" 'tag '
[[ "$(<"$CASE_DIR/conf/hashes.txt")" == "$digest_hashes" ]] || fail 'failed build committed hash state'
echo 'ok - failed builds never commit hashes or promote aliases'
