#!/usr/bin/env bash
set -euo pipefail

TEST_PATH="$(realpath "${BASH_SOURCE[0]}")"
TEST_DIR="$(dirname "$TEST_PATH")"
REPO_ROOT="$(realpath "$TEST_DIR/../..")"
DETECTOR="$REPO_ROOT/src/bin/check-joomla-releases.sh"
FIXTURES="$TEST_DIR/fixtures"
TEST_TMP="$(mktemp -d)"

cleanup() {
	rm -rf -- "$TEST_TMP"
}
trap cleanup EXIT

fail() {
	echo "not ok - $*" >&2
	exit 1
}

assert_file_contains() {
	local file="$1"
	local expected="$2"

	grep -Fqx "$expected" "$file" || fail "$file does not contain: $expected"
}

assert_json_value() {
	local file="$1"
	local filter="$2"
	local expected="$3"
	local actual

	actual="$(jq -r "$filter" "$file")"
	[[ "$actual" == "$expected" ]] || fail "$filter in $file: expected '$expected', got '$actual'"
}

prepare_case() {
	local name="$1"
	local case_dir="$TEST_TMP/$name"

	mkdir -p "$case_dir"
	cp "$FIXTURES/versions.json" "$case_dir/versions.json"
	cp "$FIXTURES/upstream-images.json" "$case_dir/upstream-images.json"
	printf '%s\n' "$case_dir"
}

combine_docker_fixtures() {
	local output="$1"
	shift

	jq -s '{results: [.[].results[]]}' "$@" > "$output"
}

run_detector() {
	local versions_file="$1"
	local state_file="$2"
	local releases_file="$3"
	local docker_tags_file="$4"
	local output_file="$5"

	GITHUB_OUTPUT="$output_file" "$DETECTOR" \
		--quiet \
		--versions-file "$versions_file" \
		--state-file "$state_file" \
		--releases-file "$releases_file" \
		--docker-tags-file "$docker_tags_file"
}

test_no_change() {
	local case_dir
	case_dir="$(prepare_case no-change)"
	cp "$case_dir/versions.json" "$case_dir/versions.before"
	cp "$case_dir/upstream-images.json" "$case_dir/upstream-images.before"

	run_detector \
		"$case_dir/versions.json" \
		"$case_dir/upstream-images.json" \
		"$FIXTURES/releases-current.json" \
		"$FIXTURES/docker-tags-current.json" \
		"$case_dir/github-output"

	cmp -s "$case_dir/versions.before" "$case_dir/versions.json" || fail "no-op rewrote versions.json"
	cmp -s "$case_dir/upstream-images.before" "$case_dir/upstream-images.json" || fail "no-op rewrote digest state"
	assert_file_contains "$case_dir/github-output" "changed=no"
	assert_file_contains "$case_dir/github-output" "versions_changed=no"
	assert_file_contains "$case_dir/github-output" "digests_changed=no"
}

test_all_candidate_tags_ready() {
	local case_dir
	case_dir="$(prepare_case all-ready)"
	combine_docker_fixtures \
		"$case_dir/docker-tags.json" \
		"$FIXTURES/docker-tags-current.json" \
		"$FIXTURES/docker-tags-five-ready.json"

	chmod 0640 "$case_dir/versions.json" "$case_dir/upstream-images.json"
	run_detector \
		"$case_dir/versions.json" \
		"$case_dir/upstream-images.json" \
		"$FIXTURES/releases-five-new.json" \
		"$case_dir/docker-tags.json" \
		"$case_dir/github-output"

	assert_json_value "$case_dir/versions.json" '.["5"].joomla' "5.4.9"
	assert_json_value "$case_dir/versions.json" '.["5"].php | join(",")' "8.2,8.3"
	assert_json_value "$case_dir/versions.json" '.["5"].variants | join(",")' "fpm,apache"
	assert_json_value "$case_dir/upstream-images.json" '.tags | length' "11"
	assert_json_value "$case_dir/upstream-images.json" '.tags["5.4.9-php8.3-apache"]' \
		"sha256:5555555555555555555555555555555555555555555555555555555555555555"
	assert_json_value "$case_dir/upstream-images.json" '.tags | has("5.4.8-php8.3-apache")' "false"
	[[ "$(stat -c '%a' "$case_dir/versions.json")" == "640" ]] || fail "versions.json mode was not preserved"
	[[ "$(stat -c '%a' "$case_dir/upstream-images.json")" == "640" ]] || fail "state mode was not preserved"
	if compgen -G "$case_dir/*.tmp.*" >/dev/null; then
		fail "atomic update left temporary files behind"
	fi
	assert_file_contains "$case_dir/github-output" "changed=yes"
	assert_file_contains "$case_dir/github-output" "versions_changed=yes"
	assert_file_contains "$case_dir/github-output" "digests_changed=yes"
	assert_file_contains "$case_dir/github-output" "updated_majors=5"
}

test_one_candidate_tag_missing() {
	local case_dir
	case_dir="$(prepare_case one-missing)"
	combine_docker_fixtures \
		"$case_dir/docker-tags.json" \
		"$FIXTURES/docker-tags-current.json" \
		"$FIXTURES/docker-tags-six-one-missing.json"
	cp "$case_dir/versions.json" "$case_dir/versions.before"
	cp "$case_dir/upstream-images.json" "$case_dir/upstream-images.before"

	run_detector \
		"$case_dir/versions.json" \
		"$case_dir/upstream-images.json" \
		"$FIXTURES/releases-six-new.json" \
		"$case_dir/docker-tags.json" \
		"$case_dir/github-output"

	cmp -s "$case_dir/versions.before" "$case_dir/versions.json" || fail "pending candidate changed versions.json"
	cmp -s "$case_dir/upstream-images.before" "$case_dir/upstream-images.json" || fail "pending candidate changed digest state"
	assert_file_contains "$case_dir/github-output" "changed=no"
	assert_file_contains "$case_dir/github-output" "waiting_majors=6"
}

test_prerelease_and_downgrade_are_ignored() {
	local release_fixture
	local case_dir

	for release_fixture in releases-prerelease.json releases-downgrade.json; do
		case_dir="$(prepare_case "${release_fixture%.json}")"
		cp "$case_dir/versions.json" "$case_dir/versions.before"
		cp "$case_dir/upstream-images.json" "$case_dir/upstream-images.before"

		run_detector \
			"$case_dir/versions.json" \
			"$case_dir/upstream-images.json" \
			"$FIXTURES/$release_fixture" \
			"$FIXTURES/docker-tags-current.json" \
			"$case_dir/github-output"

		cmp -s "$case_dir/versions.before" "$case_dir/versions.json" || fail "$release_fixture changed versions.json"
		cmp -s "$case_dir/upstream-images.before" "$case_dir/upstream-images.json" || fail "$release_fixture changed digest state"
		assert_file_contains "$case_dir/github-output" "changed=no"
	done
}

test_digest_change_triggers_without_version_change() {
	local case_dir
	case_dir="$(prepare_case digest-change)"
	cp "$case_dir/versions.json" "$case_dir/versions.before"

	run_detector \
		"$case_dir/versions.json" \
		"$case_dir/upstream-images.json" \
		"$FIXTURES/releases-current.json" \
		"$FIXTURES/docker-tags-current-digest-change.json" \
		"$case_dir/github-output"

	cmp -s "$case_dir/versions.before" "$case_dir/versions.json" || fail "digest-only change rewrote versions.json"
	assert_json_value "$case_dir/upstream-images.json" '.tags["5.4.8-php8.3-apache"]' \
		"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	assert_file_contains "$case_dir/github-output" "changed=yes"
	assert_file_contains "$case_dir/github-output" "versions_changed=no"
	assert_file_contains "$case_dir/github-output" "digests_changed=yes"
}

test_pending_candidate_still_detects_current_digest_change() {
	local case_dir
	case_dir="$(prepare_case pending-with-drift)"
	combine_docker_fixtures \
		"$case_dir/docker-tags.json" \
		"$FIXTURES/docker-tags-current-digest-change.json" \
		"$FIXTURES/docker-tags-six-one-missing.json"
	cp "$case_dir/versions.json" "$case_dir/versions.before"

	run_detector \
		"$case_dir/versions.json" \
		"$case_dir/upstream-images.json" \
		"$FIXTURES/releases-six-new.json" \
		"$case_dir/docker-tags.json" \
		"$case_dir/github-output"

	cmp -s "$case_dir/versions.before" "$case_dir/versions.json" || fail "pending candidate advanced versions.json"
	assert_json_value "$case_dir/upstream-images.json" '.tags["5.4.8-php8.3-apache"]' \
		"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	assert_file_contains "$case_dir/github-output" "changed=yes"
	assert_file_contains "$case_dir/github-output" "versions_changed=no"
	assert_file_contains "$case_dir/github-output" "digests_changed=yes"
	assert_file_contains "$case_dir/github-output" "waiting_majors=6"
}

test_missing_current_tag_is_an_error() {
	local case_dir
	case_dir="$(prepare_case missing-current)"
	jq 'del(.results[-1])' "$FIXTURES/docker-tags-current.json" > "$case_dir/docker-tags.json"
	cp "$case_dir/versions.json" "$case_dir/versions.before"
	cp "$case_dir/upstream-images.json" "$case_dir/upstream-images.before"

	if run_detector \
		"$case_dir/versions.json" \
		"$case_dir/upstream-images.json" \
		"$FIXTURES/releases-current.json" \
		"$case_dir/docker-tags.json" \
		"$case_dir/github-output" \
		2>/dev/null; then
		fail "an unavailable configured Docker tag succeeded"
	fi

	cmp -s "$case_dir/versions.before" "$case_dir/versions.json" || fail "missing current tag changed versions.json"
	cmp -s "$case_dir/upstream-images.before" "$case_dir/upstream-images.json" || fail "missing current tag changed digest state"
}

test_invalid_release_payload_fails_without_mutation() {
	local case_dir
	case_dir="$(prepare_case invalid-release)"
	cp "$case_dir/versions.json" "$case_dir/versions.before"
	cp "$case_dir/upstream-images.json" "$case_dir/upstream-images.before"

	if run_detector \
		"$case_dir/versions.json" \
		"$case_dir/upstream-images.json" \
		"$FIXTURES/releases-invalid.json" \
		"$FIXTURES/docker-tags-empty.json" \
		"$case_dir/github-output" \
		2>/dev/null; then
		fail "invalid Joomla release payload succeeded"
	fi

	cmp -s "$case_dir/versions.before" "$case_dir/versions.json" || fail "invalid payload changed versions.json"
	cmp -s "$case_dir/upstream-images.before" "$case_dir/upstream-images.json" || fail "invalid payload changed digest state"
}

test_no_change
echo "ok - current versions and digests are a byte-for-byte no-op"
test_all_candidate_tags_ready
echo "ok - a stable release advances only after its complete Docker matrix is active"
test_one_candidate_tag_missing
echo "ok - one missing candidate tag is a successful no-op"
test_prerelease_and_downgrade_are_ignored
echo "ok - prereleases and downgrades are ignored"
test_digest_change_triggers_without_version_change
echo "ok - a rebuilt upstream tag triggers a digest-only change"
test_pending_candidate_still_detects_current_digest_change
echo "ok - a pending release does not hide current-tag digest drift"
test_missing_current_tag_is_an_error
echo "ok - an unavailable configured tag is a visible failure"
test_invalid_release_payload_fails_without_mutation
echo "ok - invalid upstream data fails without mutation"
