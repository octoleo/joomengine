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

prepare_multi_platform_case() {
	local name="$1"
	local case_dir="$TEST_TMP/$name"

	mkdir -p "$case_dir"
	cp "$FIXTURES/versions-multi-platform.json" "$case_dir/versions.json"
	cp "$FIXTURES/upstream-images-multi-platform.json" "$case_dir/upstream-images.json"
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
	local official_images_file="${6:-$FIXTURES/official-images.txt}"

	GITHUB_OUTPUT="$output_file" "$DETECTOR" \
		--quiet \
		--versions-file "$versions_file" \
		--state-file "$state_file" \
		--releases-file "$releases_file" \
		--docker-tags-file "$docker_tags_file" \
		--official-images-file "$official_images_file"
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
	assert_json_value "$case_dir/upstream-images.json" '.tags["5.4.9-php8.3-apache"].index_digest' \
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
	assert_json_value "$case_dir/upstream-images.json" '.tags["5.4.8-php8.3-apache"].index_digest' \
		"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	assert_json_value "$case_dir/upstream-images.json" \
		'.tags["5.4.8-php8.3-apache"].platforms["linux/amd64"]' \
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
	assert_json_value "$case_dir/upstream-images.json" '.tags["5.4.8-php8.3-apache"].index_digest' \
		"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	assert_json_value "$case_dir/upstream-images.json" \
		'.tags["5.4.8-php8.3-apache"].platforms["linux/amd64"]' \
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

test_platform_normalization_is_deterministic() {
	local case_dir
	case_dir="$(prepare_multi_platform_case platform-normalization)"
	cp "$case_dir/upstream-images.json" "$case_dir/upstream-images.before"
	jq '.results[0].images |= reverse' \
		"$FIXTURES/docker-tags-multi-platform.json" > "$case_dir/docker-tags.json"

	run_detector \
		"$case_dir/versions.json" \
		"$case_dir/upstream-images.json" \
		"$FIXTURES/releases-multi-platform-current.json" \
		"$case_dir/docker-tags.json" \
		"$case_dir/github-output" \
		"$FIXTURES/official-images-multi-platform.txt"

	cmp -s "$case_dir/upstream-images.before" "$case_dir/upstream-images.json" || fail "platform order caused state churn"
	assert_json_value "$case_dir/upstream-images.json" \
		'.tags["4.4.14-php8.1-apache"].platforms | keys | join(",")' \
		"linux/386,linux/amd64,linux/arm/v5,linux/arm/v7,linux/arm64/v8,linux/ppc64le"
	assert_file_contains "$case_dir/github-output" "changed=no"
}

test_complete_multi_platform_candidate_advances() {
	local case_dir
	case_dir="$(prepare_multi_platform_case multi-platform-ready)"

	run_detector \
		"$case_dir/versions.json" \
		"$case_dir/upstream-images.json" \
		"$FIXTURES/releases-multi-platform-new.json" \
		"$FIXTURES/docker-tags-multi-platform.json" \
		"$case_dir/github-output" \
		"$FIXTURES/official-images-multi-platform.txt"

	assert_json_value "$case_dir/versions.json" '.["4"].joomla' "4.4.15"
	assert_json_value "$case_dir/upstream-images.json" \
		'.tags["4.4.15-php8.1-apache"].index_digest' \
		"sha256:2222222222222222222222222222222222222222222222222222222222222222"
	assert_json_value "$case_dir/upstream-images.json" \
		'.tags["4.4.15-php8.1-apache"].platforms["linux/arm64/v8"]' \
		"sha256:4444444444444444444444444444444444444444444444444444444444444444"
	assert_json_value "$case_dir/upstream-images.json" \
		'.tags | has("4.4.14-php8.1-apache")' "false"
}

test_published_platform_set_is_authoritative() {
	local platform_change
	local case_dir
	local expected_count

	for platform_change in removed added; do
		case_dir="$(prepare_multi_platform_case "published-$platform_change")"

		if [[ "$platform_change" == "removed" ]]; then
			jq '(.results[] | select(.name == "4.4.15-php8.1-apache") | .images) |=
				map(select(.architecture != "ppc64le"))' \
				"$FIXTURES/docker-tags-multi-platform.json" > "$case_dir/docker-tags.json"
			expected_count="5"
		else
			jq '(.results[] | select(.name == "4.4.15-php8.1-apache") | .images) += [{
				"architecture": "riscv64",
				"os": "linux",
				"status": "active",
				"digest": "sha256:7777777777777777777777777777777777777777777777777777777777777777"
			}]' "$FIXTURES/docker-tags-multi-platform.json" > "$case_dir/docker-tags.json"
			expected_count="7"
		fi

		run_detector \
			"$case_dir/versions.json" \
			"$case_dir/upstream-images.json" \
			"$FIXTURES/releases-multi-platform-new.json" \
			"$case_dir/docker-tags.json" \
			"$case_dir/github-output" \
			"$FIXTURES/official-images-multi-platform.txt"

		assert_json_value "$case_dir/versions.json" '.["4"].joomla' "4.4.15"
		assert_json_value "$case_dir/upstream-images.json" \
			'.tags["4.4.15-php8.1-apache"].platforms | length' "$expected_count"
		assert_file_contains "$case_dir/github-output" "updated_majors=4"
		assert_file_contains "$case_dir/github-output" "waiting_majors="
	done
}

test_current_platform_change_refreshes_state() {
	local case_dir
	case_dir="$(prepare_multi_platform_case current-platform-change)"
	cp "$case_dir/versions.json" "$case_dir/versions.before"
	jq '(.results[] | select(.name == "4.4.14-php8.1-apache") | .images) |=
		map(select(.architecture != "ppc64le"))' \
		"$FIXTURES/docker-tags-multi-platform.json" > "$case_dir/docker-tags.json"

	run_detector \
		"$case_dir/versions.json" \
		"$case_dir/upstream-images.json" \
		"$FIXTURES/releases-multi-platform-current.json" \
		"$case_dir/docker-tags.json" \
		"$case_dir/github-output" \
		"$FIXTURES/official-images-multi-platform.txt"

	cmp -s "$case_dir/versions.before" "$case_dir/versions.json" || fail "platform change rewrote versions"
	assert_json_value "$case_dir/upstream-images.json" \
		'.tags["4.4.14-php8.1-apache"].platforms | has("linux/ppc64le")' "false"
	assert_json_value "$case_dir/upstream-images.json" \
		'.tags["4.4.14-php8.1-apache"].platforms | length' "5"
	assert_file_contains "$case_dir/github-output" "digests_changed=yes"
}

test_duplicate_canonical_platform_is_an_error() {
	local case_dir
	case_dir="$(prepare_multi_platform_case duplicate-platform)"
	cp "$case_dir/upstream-images.json" "$case_dir/upstream-images.before"
	jq '(.results[] | select(.name == "4.4.14-php8.1-apache") | .images) += [{
		"architecture": "amd64",
		"os": "linux",
		"status": "active",
		"digest": "sha256:6666666666666666666666666666666666666666666666666666666666666666"
	}]' "$FIXTURES/docker-tags-multi-platform.json" > "$case_dir/docker-tags.json"

	if run_detector \
		"$case_dir/versions.json" \
		"$case_dir/upstream-images.json" \
		"$FIXTURES/releases-multi-platform-current.json" \
		"$case_dir/docker-tags.json" \
		"$case_dir/github-output" \
		"$FIXTURES/official-images-multi-platform.txt" \
		2>/dev/null; then
		fail "duplicate normalized Docker platforms succeeded"
	fi

	cmp -s "$case_dir/upstream-images.before" "$case_dir/upstream-images.json" || fail "duplicate platforms changed state"
}

test_schema_one_migrates_legacy_platforms_once() {
	local case_dir
	case_dir="$(prepare_multi_platform_case schema-one-migration)"
	jq '{schema: 1, repository, tags: (.tags | with_entries(.value = .value.platforms["linux/amd64"]))}' \
		"$case_dir/upstream-images.json" > "$case_dir/upstream-images.schema-one"
	mv "$case_dir/upstream-images.schema-one" "$case_dir/upstream-images.json"
	printf '%s\n' \
		'Tags: unrelated' \
		'Architectures: amd64' > "$case_dir/legacy-official-images.txt"

	run_detector \
		"$case_dir/versions.json" \
		"$case_dir/upstream-images.json" \
		"$FIXTURES/releases-multi-platform-current.json" \
		"$FIXTURES/docker-tags-multi-platform.json" \
		"$case_dir/github-output" \
		"$case_dir/legacy-official-images.txt"

	assert_json_value "$case_dir/upstream-images.json" '.schema' "2"
	assert_json_value "$case_dir/upstream-images.json" \
		'.tags["4.4.14-php8.1-apache"].platforms | length' "6"
	assert_file_contains "$case_dir/github-output" "digests_changed=yes"
	cp "$case_dir/upstream-images.json" "$case_dir/upstream-images.before"

	run_detector \
		"$case_dir/versions.json" \
		"$case_dir/upstream-images.json" \
		"$FIXTURES/releases-multi-platform-current.json" \
		"$FIXTURES/docker-tags-multi-platform.json" \
		"$case_dir/github-output-second" \
		"$case_dir/legacy-official-images.txt"

	cmp -s "$case_dir/upstream-images.before" "$case_dir/upstream-images.json" || fail "legacy schema-two fallback rewrote stable state"
	assert_file_contains "$case_dir/github-output-second" "changed=no"
}

test_published_index_can_remove_a_platform() {
	local case_dir
	case_dir="$(prepare_multi_platform_case authoritative-removal)"
	jq '.tags["4.4.14-php8.1-apache"].platforms["linux/riscv64"] =
		"sha256:8888888888888888888888888888888888888888888888888888888888888888"' \
		"$case_dir/upstream-images.json" > "$case_dir/upstream-images.with-extra"
	mv "$case_dir/upstream-images.with-extra" "$case_dir/upstream-images.json"

	run_detector \
		"$case_dir/versions.json" \
		"$case_dir/upstream-images.json" \
		"$FIXTURES/releases-multi-platform-current.json" \
		"$FIXTURES/docker-tags-multi-platform.json" \
		"$case_dir/github-output" \
		"$FIXTURES/official-images-multi-platform.txt"

	assert_json_value "$case_dir/upstream-images.json" \
		'.tags["4.4.14-php8.1-apache"].platforms | has("linux/riscv64")' "false"
	assert_file_contains "$case_dir/github-output" "digests_changed=yes"
}

test_invalid_fixture_and_state_are_rejected() {
	local case_dir
	local invalid_kind

	for invalid_kind in index-digest platform-digest platform-name arm-variant invalid-state-platform; do
		case_dir="$(prepare_multi_platform_case "$invalid_kind")"
		cp "$FIXTURES/docker-tags-multi-platform.json" "$case_dir/docker-tags.json"

		case "$invalid_kind" in
			index-digest)
				jq '.results[0].digest = "sha256:invalid"' "$case_dir/docker-tags.json" > "$case_dir/invalid.json"
				mv "$case_dir/invalid.json" "$case_dir/docker-tags.json"
				;;
			platform-digest)
				jq '.results[0].images[1].digest = "sha256:invalid"' "$case_dir/docker-tags.json" > "$case_dir/invalid.json"
				mv "$case_dir/invalid.json" "$case_dir/docker-tags.json"
				;;
			platform-name)
				jq '.results[0].images[1].architecture = "invalid/architecture"' "$case_dir/docker-tags.json" > "$case_dir/invalid.json"
				mv "$case_dir/invalid.json" "$case_dir/docker-tags.json"
				;;
			arm-variant)
				jq '.results[0].images[2].variant = "invalid"' "$case_dir/docker-tags.json" > "$case_dir/invalid.json"
				mv "$case_dir/invalid.json" "$case_dir/docker-tags.json"
				;;
			invalid-state-platform)
				jq '.tags["4.4.14-php8.1-apache"].platforms["linux/unknown"] =
					"sha256:7777777777777777777777777777777777777777777777777777777777777777"' \
					"$case_dir/upstream-images.json" > "$case_dir/invalid.json"
				mv "$case_dir/invalid.json" "$case_dir/upstream-images.json"
				;;
		esac
		cp "$case_dir/upstream-images.json" "$case_dir/upstream-images.before"
		cp "$case_dir/versions.json" "$case_dir/versions.before"

		if run_detector \
			"$case_dir/versions.json" \
			"$case_dir/upstream-images.json" \
			"$FIXTURES/releases-multi-platform-current.json" \
			"$case_dir/docker-tags.json" \
			"$case_dir/github-output" \
			2>/dev/null; then
			fail "$invalid_kind succeeded"
		fi

		cmp -s "$case_dir/versions.before" "$case_dir/versions.json" || fail "$invalid_kind changed versions"
		cmp -s "$case_dir/upstream-images.before" "$case_dir/upstream-images.json" || fail "$invalid_kind changed state"
	done
}

test_candidate_does_not_require_official_metadata() {
	local case_dir
	case_dir="$(prepare_multi_platform_case candidate-metadata-missing)"
	awk 'BEGIN { RS = ""; ORS = "\n\n" } /Tags: 4.4.14-php8.1-apache/ { print }' \
		"$FIXTURES/official-images-multi-platform.txt" > "$case_dir/current-only-official-images.txt"

	run_detector \
		"$case_dir/versions.json" \
		"$case_dir/upstream-images.json" \
		"$FIXTURES/releases-multi-platform-new.json" \
		"$FIXTURES/docker-tags-multi-platform.json" \
		"$case_dir/github-output" \
		"$case_dir/current-only-official-images.txt"

	assert_json_value "$case_dir/versions.json" '.["4"].joomla' "4.4.15"
	assert_file_contains "$case_dir/github-output" "updated_majors=4"
}

test_refresh_current_does_not_upgrade_versions() {
	local case_dir
	case_dir="$(prepare_multi_platform_case refresh-current)"
	cp "$case_dir/versions.json" "$case_dir/versions.before"
	rm "$case_dir/upstream-images.json"

	GITHUB_OUTPUT="$case_dir/github-output" "$DETECTOR" \
		--quiet --refresh-current \
		--versions-file "$case_dir/versions.json" \
		--state-file "$case_dir/upstream-images.json" \
		--releases-file "$FIXTURES/releases-multi-platform-new.json" \
		--docker-tags-file "$FIXTURES/docker-tags-multi-platform.json"

	cmp -s "$case_dir/versions.before" "$case_dir/versions.json" || fail "refresh-current advanced Joomla version"
	assert_json_value "$case_dir/upstream-images.json" '.tags | keys | join(",")' "4.4.14-php8.1-apache"
	assert_file_contains "$case_dir/github-output" "versions_changed=no"
	assert_file_contains "$case_dir/github-output" "digests_changed=yes"
	assert_file_contains "$case_dir/github-output" "updated_majors="
}

prepare_profile_case() {
	local case_dir
	case_dir="$(prepare_case "$1")"
	jq 'with_entries(.value.profiles = ["standard"]) |
		.["6"].profiles = ["standard", "dev"]' \
		"$case_dir/versions.json" > "$case_dir/versions.next"
	mv "$case_dir/versions.next" "$case_dir/versions.json"
	jq '.tags += (.tags | with_entries(select(.key | startswith("6.")) | .key += "-dev"))' \
		"$case_dir/upstream-images.json" > "$case_dir/state.next"
	mv "$case_dir/state.next" "$case_dir/upstream-images.json"
	jq '.results += [.results[] | select(.name | startswith("6.")) | .name += "-dev"]' \
		"$FIXTURES/docker-tags-current.json" > "$case_dir/current-tags.json"
	jq '.results += [.results[] | select(.name | startswith("6.")) |
		.name |= sub("^6.1.3"; "6.1.4")]' \
		"$case_dir/current-tags.json" > "$case_dir/candidate-tags.json"
	printf '%s\n' "$case_dir"
}

test_all_profiles_are_required_before_promotion() {
	local case_dir
	case_dir="$(prepare_profile_case profile-readiness)"
	cp "$case_dir/versions.json" "$case_dir/versions.before"
	# Standard images alone cannot promote a release whose dev matrix is configured.
	jq ' .results |= map(select(.name != "6.1.4-php8.4-apache-dev"))' \
		"$case_dir/candidate-tags.json" > "$case_dir/pending-tags.json"
	run_detector "$case_dir/versions.json" "$case_dir/upstream-images.json" \
		"$FIXTURES/releases-six-new.json" "$case_dir/pending-tags.json" "$case_dir/pending-output"
	cmp -s "$case_dir/versions.before" "$case_dir/versions.json" || fail "missing dev image advanced Joomla"
	assert_file_contains "$case_dir/pending-output" 'waiting_majors=6'
	assert_file_contains "$case_dir/pending-output" 'versions_changed=no'
	assert_json_value "$case_dir/upstream-images.json" '.tags | has("6.1.4-php8.3-fpm")' false

	run_detector "$case_dir/versions.json" "$case_dir/upstream-images.json" \
		"$FIXTURES/releases-six-new.json" "$case_dir/candidate-tags.json" "$case_dir/ready-output"
	assert_json_value "$case_dir/versions.json" '.["6"].joomla' 6.1.4
	assert_json_value "$case_dir/versions.json" '.["6"].profiles | join(",")' standard,dev
	assert_json_value "$case_dir/upstream-images.json" '.tags | has("6.1.4-php8.4-apache-dev")' true
	assert_json_value "$case_dir/upstream-images.json" '.tags | has("6.1.3-php8.4-apache-dev")' false
	assert_json_value "$case_dir/upstream-images.json" '.tags | keys | map(select(test("^[45].*-dev$"))) | length' 0
	assert_file_contains "$case_dir/ready-output" 'updated_majors=6'
}

test_dev_digest_drift_without_version_change() {
	local case_dir
	case_dir="$(prepare_profile_case dev-digest-drift)"
	# Prime normalized state so only the subsequent dev change is observed.
	run_detector "$case_dir/versions.json" "$case_dir/upstream-images.json" \
		"$FIXTURES/releases-current.json" "$case_dir/current-tags.json" "$case_dir/initial-output"
	cp "$case_dir/upstream-images.json" "$case_dir/state.before"
	cp "$case_dir/versions.json" "$case_dir/versions.before"
	jq '(.results[] | select(.name == "6.1.3-php8.4-apache-dev")) |=
		(.digest = "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd" |
		.images[0].digest = "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")' \
		"$case_dir/current-tags.json" > "$case_dir/drift-tags.json"
	run_detector "$case_dir/versions.json" "$case_dir/upstream-images.json" \
		"$FIXTURES/releases-current.json" "$case_dir/drift-tags.json" "$case_dir/drift-output"
	cmp -s "$case_dir/versions.before" "$case_dir/versions.json" || fail "dev drift changed Joomla version"
	assert_json_value "$case_dir/upstream-images.json" '.tags["6.1.3-php8.4-apache-dev"].index_digest' \
		sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
	jq 'del(.tags["6.1.3-php8.4-apache-dev"])' "$case_dir/state.before" > "$case_dir/standard.before"
	jq 'del(.tags["6.1.3-php8.4-apache-dev"])' "$case_dir/upstream-images.json" > "$case_dir/standard.after"
	cmp -s "$case_dir/standard.before" "$case_dir/standard.after" || fail "dev drift changed unrelated image state"
	assert_file_contains "$case_dir/drift-output" 'versions_changed=no'
	assert_file_contains "$case_dir/drift-output" 'digests_changed=yes'
}

test_profiles_never_enable_downgrades() {
	local case_dir
	case_dir="$(prepare_profile_case profiles-no-downgrade)"
	cp "$case_dir/versions.json" "$case_dir/versions.before"
	run_detector "$case_dir/versions.json" "$case_dir/upstream-images.json" \
		"$FIXTURES/releases-downgrade.json" "$case_dir/current-tags.json" "$case_dir/github-output"
	cmp -s "$case_dir/versions.before" "$case_dir/versions.json" || fail "profile matrix allowed a downgrade"
	assert_file_contains "$case_dir/github-output" 'versions_changed=no'
	assert_file_contains "$case_dir/github-output" 'updated_majors='
}

test_missing_current_dev_image_fails_without_mutation() {
	local case_dir
	case_dir="$(prepare_profile_case missing-current-dev)"
	cp "$case_dir/versions.json" "$case_dir/versions.before"
	cp "$case_dir/upstream-images.json" "$case_dir/state.before"
	jq '.results |= map(select(.name != "6.1.3-php8.4-apache-dev"))' \
		"$case_dir/current-tags.json" > "$case_dir/missing-tags.json"
	if run_detector "$case_dir/versions.json" "$case_dir/upstream-images.json" \
		"$FIXTURES/releases-current.json" "$case_dir/missing-tags.json" "$case_dir/github-output" \
		> "$case_dir/stdout" 2> "$case_dir/stderr"; then
		fail "unavailable configured dev tag succeeded"
	fi
	cmp -s "$case_dir/versions.before" "$case_dir/versions.json" || fail "missing dev tag changed versions"
	cmp -s "$case_dir/state.before" "$case_dir/upstream-images.json" || fail "missing dev tag changed state"
	grep -Fq '6.1.3-php8.4-apache-dev' "$case_dir/stderr" || fail "missing dev diagnostic omitted tag"
}

test_invalid_profile_matrix_fails_without_mutation() {
	local profiles case_dir
	for profiles in 'null' '[]' '["unknown"]' '["standard", "standard"]' '"dev"' '[1]'; do
		case_dir="$(prepare_profile_case "invalid-profile-${RANDOM}")"
		jq --argjson profiles "$profiles" '.["6"].profiles = $profiles' \
			"$case_dir/versions.json" > "$case_dir/versions.next"
		mv "$case_dir/versions.next" "$case_dir/versions.json"
		cp "$case_dir/versions.json" "$case_dir/versions.before"
		cp "$case_dir/upstream-images.json" "$case_dir/state.before"
		if run_detector "$case_dir/versions.json" "$case_dir/upstream-images.json" \
			"$FIXTURES/releases-current.json" "$case_dir/current-tags.json" "$case_dir/github-output" \
			> "$case_dir/stdout" 2> "$case_dir/stderr"; then
			fail "invalid profiles accepted: $profiles"
		fi
		cmp -s "$case_dir/versions.before" "$case_dir/versions.json" || fail "invalid profiles changed versions"
		cmp -s "$case_dir/state.before" "$case_dir/upstream-images.json" || fail "invalid profiles changed state"
	done
}

prepare_targets_case() {
	local case_dir
	case_dir="$(prepare_case "$1")"
	cp "$FIXTURES/versions-targets.json" "$case_dir/versions.json"
	rm "$case_dir/upstream-images.json"
	# These target/tag fixtures are synthetic; they do not assert publication.
	jq '[.results[] | select(.name == "6.1.3-php8.3-apache")][0] as $image |
		{results: [
			"6.1.3-php8.3-apache", "6.1.3-php8.3-apache-dev",
			"6.1.4-php8.3-apache", "6.1.4-php8.3-apache-dev",
			"7.0.0-alpha1-php8.3-apache-dev", "6.2.0-beta1-php8.3-apache-dev",
			"6.2.0-rc1-php8.3-apache-dev"
		] | map(. as $name | $image | .name = $name)}' \
		"$FIXTURES/docker-tags-current.json" > "$case_dir/docker-tags.json"
	printf '%s\n' "$case_dir"
}

test_target_updates_preserve_shared_pinned_bases() {
	local case_dir
	case_dir="$(prepare_targets_case shared-target-base)"
	run_detector "$case_dir/versions.json" "$case_dir/upstream-images.json" \
		"$FIXTURES/releases-six-new.json" "$case_dir/docker-tags.json" "$case_dir/github-output"
	assert_json_value "$case_dir/versions.json" '.["joomla6-stable"].joomla' 6.1.4
	assert_json_value "$case_dir/versions.json" '.["joomla6-pinned"].joomla' 6.1.3
	assert_json_value "$case_dir/versions.json" '.["joomla6-stable"].jcb.versions' latest-stable
	assert_json_value "$case_dir/versions.json" '.["joomla6-pinned"].jcb.versions | join(",")' 6.2.0
	assert_json_value "$case_dir/upstream-images.json" '.tags | has("6.1.3-php8.3-apache")' true
	assert_json_value "$case_dir/upstream-images.json" '.tags | has("6.1.3-php8.3-apache-dev")' true
	assert_json_value "$case_dir/upstream-images.json" '.tags | has("6.1.4-php8.3-apache-dev")' true
	assert_json_value "$case_dir/upstream-images.json" '.tags | length' 7
	assert_file_contains "$case_dir/github-output" 'updated_targets=joomla6-stable'
	assert_file_contains "$case_dir/github-output" 'updated_majors=6'
	assert_file_contains "$case_dir/github-output" 'waiting_targets='
	# Existing preview records must pass validation and remain stable next time.
	cp "$case_dir/upstream-images.json" "$case_dir/state.before"
	run_detector "$case_dir/versions.json" "$case_dir/upstream-images.json" \
		"$FIXTURES/releases-six-new.json" "$case_dir/docker-tags.json" "$case_dir/second-output"
	cmp -s "$case_dir/state.before" "$case_dir/upstream-images.json" || fail "pinned preview state churned"
	assert_file_contains "$case_dir/second-output" 'changed=no'
}

test_named_target_readiness_outputs() {
	local case_dir
	case_dir="$(prepare_targets_case pending-named-target)"
	jq '.results |= map(select(.name != "6.1.4-php8.3-apache-dev"))' \
		"$case_dir/docker-tags.json" > "$case_dir/pending-tags.json"
	run_detector "$case_dir/versions.json" "$case_dir/upstream-images.json" \
		"$FIXTURES/releases-six-new.json" "$case_dir/pending-tags.json" "$case_dir/github-output"
	assert_json_value "$case_dir/versions.json" '.["joomla6-stable"].joomla' 6.1.3
	assert_json_value "$case_dir/upstream-images.json" '.tags | has("6.1.4-php8.3-apache")' false
	assert_file_contains "$case_dir/github-output" 'waiting_targets=joomla6-stable'
	assert_file_contains "$case_dir/github-output" 'waiting_majors=6'
	assert_file_contains "$case_dir/github-output" 'updated_targets='
}

test_pinned_channels_ignore_stable_release_updates() {
	local case_dir
	case_dir="$(prepare_targets_case pinned-channels)"
	jq 'with_entries(.value.update = "pinned")' "$case_dir/versions.json" > "$case_dir/versions.next"
	mv "$case_dir/versions.next" "$case_dir/versions.json"
	cp "$case_dir/versions.json" "$case_dir/versions.before"
	printf '%s\n' '{"branches":[{"branch":"Joomla! 6","version":"6.2.0"},{"branch":"Joomla! 7","version":"7.0.0"}]}' \
		> "$case_dir/stable-releases.json"
	run_detector "$case_dir/versions.json" "$case_dir/upstream-images.json" \
		"$case_dir/stable-releases.json" "$case_dir/docker-tags.json" "$case_dir/github-output"
	cmp -s "$case_dir/versions.before" "$case_dir/versions.json" || fail "stable feed promoted a pinned channel"
	assert_json_value "$case_dir/upstream-images.json" '.tags | has("7.0.0-alpha1-php8.3-apache-dev")' true
	assert_json_value "$case_dir/upstream-images.json" '.tags | has("6.2.0-beta1-php8.3-apache-dev")' true
	assert_json_value "$case_dir/upstream-images.json" '.tags | has("6.2.0-rc1-php8.3-apache-dev")' true
	assert_file_contains "$case_dir/github-output" 'updated_targets='
	# A release feed is not an input to an all-pinned target set.
	printf '%s\n' '{"not":"a release feed"}' > "$case_dir/stable-releases.json"
	run_detector "$case_dir/versions.json" "$case_dir/upstream-images.json" \
		"$case_dir/stable-releases.json" "$case_dir/docker-tags.json" "$case_dir/second-output"
	assert_file_contains "$case_dir/second-output" 'changed=no'
	jq '(.results[] | select(.name == "7.0.0-alpha1-php8.3-apache-dev")).digest =
		"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"' \
		"$case_dir/docker-tags.json" > "$case_dir/drift-tags.json"
	run_detector "$case_dir/versions.json" "$case_dir/upstream-images.json" \
		"$case_dir/stable-releases.json" "$case_dir/drift-tags.json" "$case_dir/drift-output"
	cmp -s "$case_dir/versions.before" "$case_dir/versions.json" || fail "preview digest drift changed target pin"
	assert_json_value "$case_dir/upstream-images.json" '.tags["7.0.0-alpha1-php8.3-apache-dev"].index_digest' \
		sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
	assert_file_contains "$case_dir/drift-output" 'digests_changed=yes'
}

test_joomla_target_major_is_independent_of_jcb_major() {
	local case_dir
	case_dir="$(prepare_targets_case joomla-seven-jcb-six)"
	jq '{"joomla7-stable": (.["joomla7-alpha"] |
		.joomla = "7.0.0" | .channel = "stable" | .update = "stable")}' \
		"$case_dir/versions.json" > "$case_dir/versions.next"
	mv "$case_dir/versions.next" "$case_dir/versions.json"
	jq '.results[0] as $image | {results: ["7.0.0-php8.3-apache-dev", "7.0.1-php8.3-apache-dev"] |
		map(. as $name | $image | .name = $name)}' \
		"$case_dir/docker-tags.json" > "$case_dir/seven-tags.json"
	printf '%s\n' '{"branches":[{"branch":"Joomla! 6","version":"6.9.0"},{"branch":"Joomla! 7","version":"7.0.1"}]}' \
		> "$case_dir/releases.json"
	run_detector "$case_dir/versions.json" "$case_dir/upstream-images.json" \
		"$case_dir/releases.json" "$case_dir/seven-tags.json" "$case_dir/github-output"
	assert_json_value "$case_dir/versions.json" '.["joomla7-stable"].joomla' 7.0.1
	assert_json_value "$case_dir/versions.json" '.["joomla7-stable"].jcb.major' 6
	assert_json_value "$case_dir/upstream-images.json" '.tags | keys | join(",")' 7.0.1-php8.3-apache-dev
	assert_file_contains "$case_dir/github-output" 'updated_targets=joomla7-stable'
	assert_file_contains "$case_dir/github-output" 'updated_majors=7'
}

test_unavailable_preview_fails_without_mutation() {
	local case_dir
	case_dir="$(prepare_targets_case unavailable-preview)"
	run_detector "$case_dir/versions.json" "$case_dir/upstream-images.json" \
		"$FIXTURES/releases-current.json" "$case_dir/docker-tags.json" "$case_dir/initial-output"
	cp "$case_dir/versions.json" "$case_dir/versions.before"
	cp "$case_dir/upstream-images.json" "$case_dir/state.before"
	jq '.results |= map(select(.name != "7.0.0-alpha1-php8.3-apache-dev"))' \
		"$case_dir/docker-tags.json" > "$case_dir/missing-tags.json"
	if run_detector "$case_dir/versions.json" "$case_dir/upstream-images.json" \
		"$FIXTURES/releases-six-new.json" "$case_dir/missing-tags.json" "$case_dir/github-output" \
		> "$case_dir/stdout" 2> "$case_dir/stderr"; then
		fail "unpublished active preview was accepted"
	fi
	cmp -s "$case_dir/versions.before" "$case_dir/versions.json" || fail "missing preview changed target versions"
	cmp -s "$case_dir/state.before" "$case_dir/upstream-images.json" || fail "missing preview changed state"
	[[ ! -e "$case_dir/github-output" ]] || fail "missing preview emitted success outputs"
	grep -Fq '7.0.0-alpha1-php8.3-apache-dev' "$case_dir/stderr" || fail "missing preview diagnostic omitted tag"
}

test_disabled_preview_does_not_block_active_targets() {
	local case_dir
	case_dir="$(prepare_targets_case disabled-preview)"
	jq '.["joomla7-alpha"].enabled = false' "$case_dir/versions.json" > "$case_dir/versions.next"
	mv "$case_dir/versions.next" "$case_dir/versions.json"
	jq '.results |= map(select(.name != "7.0.0-alpha1-php8.3-apache-dev"))' \
		"$case_dir/docker-tags.json" > "$case_dir/active-tags.json"
	run_detector "$case_dir/versions.json" "$case_dir/upstream-images.json" \
		"$FIXTURES/releases-six-new.json" "$case_dir/active-tags.json" "$case_dir/github-output"
	assert_json_value "$case_dir/versions.json" '.["joomla7-alpha"].enabled' false
	assert_json_value "$case_dir/versions.json" '.["joomla7-alpha"].joomla' 7.0.0-alpha1
	assert_json_value "$case_dir/versions.json" '.["joomla6-stable"].joomla' 6.1.4
	assert_json_value "$case_dir/upstream-images.json" '.tags | has("7.0.0-alpha1-php8.3-apache-dev")' false
	assert_file_contains "$case_dir/github-output" 'updated_targets=joomla6-stable'
	assert_file_contains "$case_dir/github-output" 'waiting_targets='
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
test_platform_normalization_is_deterministic
echo "ok - platform aliases, ARM variants, ordering, and attestations normalize deterministically"
test_complete_multi_platform_candidate_advances
echo "ok - a published multi-platform candidate advances"
test_published_platform_set_is_authoritative
echo "ok - published platforms determine readiness independently of planned architectures"
test_current_platform_change_refreshes_state
echo "ok - current tags refresh the actually published platform set"
test_duplicate_canonical_platform_is_an_error
echo "ok - duplicate canonical Docker platforms fail without mutation"
test_schema_one_migrates_legacy_platforms_once
echo "ok - schema one migrates legacy tags once and schema two remains stable"
test_published_index_can_remove_a_platform
echo "ok - a published index refresh removes stale platform records"
test_invalid_fixture_and_state_are_rejected
echo "ok - invalid digests, platform names, ARM variants, and state fail without mutation"
test_candidate_does_not_require_official_metadata
echo "ok - published candidate tags do not depend on official-images metadata"
test_refresh_current_does_not_upgrade_versions
echo "ok - refresh-current repairs missing digest state without upgrading Joomla"
test_all_profiles_are_required_before_promotion
echo "ok - a release waits for all configured standard/dev images without requiring unsupported dev series"
test_dev_digest_drift_without_version_change
echo "ok - development image digest drift refreshes only its own image state"
test_profiles_never_enable_downgrades
echo "ok - a profile matrix cannot cause a Joomla downgrade"
test_missing_current_dev_image_fails_without_mutation
echo "ok - a missing configured development tag fails without mutation"
test_invalid_profile_matrix_fails_without_mutation
echo "ok - empty, duplicate and unknown profiles fail without mutation"
test_target_updates_preserve_shared_pinned_bases
echo "ok - independent targets retain shared pinned bases when a stable target advances"
test_named_target_readiness_outputs
echo "ok - named targets report readiness separately from compatibility major outputs"
test_pinned_channels_ignore_stable_release_updates
echo "ok - pinned alpha, beta and RC targets never promote through the stable feed"
test_joomla_target_major_is_independent_of_jcb_major
echo "ok - a Joomla 7 target mapped to JCB 6 polls Joomla 7 releases"
test_unavailable_preview_fails_without_mutation
echo "ok - unavailable active previews fail without changing targets or digest state"
test_disabled_preview_does_not_block_active_targets
echo "ok - disabled preview targets remain configured without blocking active releases"
bash "$TEST_DIR/test-registry.sh"
