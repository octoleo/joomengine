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

test_candidate_platform_mismatch_waits() {
	local mismatch
	local case_dir

	for mismatch in missing unexpected; do
		case_dir="$(prepare_multi_platform_case "candidate-$mismatch")"
		cp "$case_dir/versions.json" "$case_dir/versions.before"
		cp "$case_dir/upstream-images.json" "$case_dir/upstream-images.before"

		if [[ "$mismatch" == "missing" ]]; then
			jq '(.results[] | select(.name == "4.4.15-php8.1-apache") | .images) |=
				map(select(.architecture != "ppc64le"))' \
				"$FIXTURES/docker-tags-multi-platform.json" > "$case_dir/docker-tags.json"
		else
			jq '(.results[] | select(.name == "4.4.15-php8.1-apache") | .images) += [{
				"architecture": "riscv64",
				"os": "linux",
				"status": "active",
				"digest": "sha256:7777777777777777777777777777777777777777777777777777777777777777"
			}]' "$FIXTURES/docker-tags-multi-platform.json" > "$case_dir/docker-tags.json"
		fi

		run_detector \
			"$case_dir/versions.json" \
			"$case_dir/upstream-images.json" \
			"$FIXTURES/releases-multi-platform-new.json" \
			"$case_dir/docker-tags.json" \
			"$case_dir/github-output" \
			"$FIXTURES/official-images-multi-platform.txt"

		cmp -s "$case_dir/versions.before" "$case_dir/versions.json" || fail "$mismatch candidate platform set advanced the release"
		cmp -s "$case_dir/upstream-images.before" "$case_dir/upstream-images.json" || fail "$mismatch candidate platform set changed state"
		assert_file_contains "$case_dir/github-output" "waiting_majors=4"
	done
}

test_current_platform_mismatch_is_an_error() {
	local case_dir
	case_dir="$(prepare_multi_platform_case current-platform-missing)"
	cp "$case_dir/versions.json" "$case_dir/versions.before"
	cp "$case_dir/upstream-images.json" "$case_dir/upstream-images.before"
	jq '(.results[] | select(.name == "4.4.14-php8.1-apache") | .images) |=
		map(select(.architecture != "ppc64le"))' \
		"$FIXTURES/docker-tags-multi-platform.json" > "$case_dir/docker-tags.json"

	if run_detector \
		"$case_dir/versions.json" \
		"$case_dir/upstream-images.json" \
		"$FIXTURES/releases-multi-platform-current.json" \
		"$case_dir/docker-tags.json" \
		"$case_dir/github-output" \
		"$FIXTURES/official-images-multi-platform.txt" \
		2>/dev/null; then
		fail "an incomplete current platform set succeeded"
	fi

	cmp -s "$case_dir/versions.before" "$case_dir/versions.json" || fail "incomplete current platforms changed versions"
	cmp -s "$case_dir/upstream-images.before" "$case_dir/upstream-images.json" || fail "incomplete current platforms changed state"
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

test_authoritative_policy_can_remove_a_platform() {
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

test_invalid_official_metadata_and_state_are_rejected() {
	local case_dir
	local invalid_kind

	for invalid_kind in unknown-architecture duplicate-stanza invalid-state-platform; do
		case_dir="$(prepare_multi_platform_case "$invalid_kind")"
		cp "$case_dir/upstream-images.json" "$case_dir/upstream-images.before"
		cp "$FIXTURES/official-images-multi-platform.txt" "$case_dir/official-images.txt"

		case "$invalid_kind" in
			unknown-architecture)
			awk '{sub("ppc64le", "not/an/architecture"); print}' \
				"$case_dir/official-images.txt" > "$case_dir/official-images.invalid"
			mv "$case_dir/official-images.invalid" "$case_dir/official-images.txt"
			;;
			duplicate-stanza)
			printf '%s\n' \
				'' \
				'Tags: 4.4.14-php8.1-apache' \
				'Architectures: amd64' >> "$case_dir/official-images.txt"
			;;
			invalid-state-platform)
			jq '.tags["4.4.14-php8.1-apache"].platforms["linux/unknown"] =
				"sha256:7777777777777777777777777777777777777777777777777777777777777777"' \
				"$case_dir/upstream-images.json" > "$case_dir/upstream-images.invalid"
			mv "$case_dir/upstream-images.invalid" "$case_dir/upstream-images.json"
			;;
		esac

		if run_detector \
			"$case_dir/versions.json" \
			"$case_dir/upstream-images.json" \
			"$FIXTURES/releases-multi-platform-current.json" \
			"$FIXTURES/docker-tags-multi-platform.json" \
			"$case_dir/github-output" \
			"$case_dir/official-images.txt" \
			2>/dev/null; then
			fail "$invalid_kind succeeded"
		fi

		if [[ "$invalid_kind" != "invalid-state-platform" ]]; then
			cmp -s "$case_dir/upstream-images.before" "$case_dir/upstream-images.json" || fail "$invalid_kind changed state"
		fi
	done
}

test_candidate_without_official_metadata_waits() {
	local case_dir
	case_dir="$(prepare_multi_platform_case candidate-metadata-missing)"
	cp "$case_dir/versions.json" "$case_dir/versions.before"
	cp "$case_dir/upstream-images.json" "$case_dir/upstream-images.before"
	awk 'BEGIN { RS = ""; ORS = "\n\n" } /Tags: 4.4.14-php8.1-apache/ { print }' \
		"$FIXTURES/official-images-multi-platform.txt" > "$case_dir/current-only-official-images.txt"

	run_detector \
		"$case_dir/versions.json" \
		"$case_dir/upstream-images.json" \
		"$FIXTURES/releases-multi-platform-new.json" \
		"$FIXTURES/docker-tags-multi-platform.json" \
		"$case_dir/github-output" \
		"$case_dir/current-only-official-images.txt"

	cmp -s "$case_dir/versions.before" "$case_dir/versions.json" || fail "candidate without official metadata advanced"
	cmp -s "$case_dir/upstream-images.before" "$case_dir/upstream-images.json" || fail "candidate without official metadata changed state"
	assert_file_contains "$case_dir/github-output" "waiting_majors=4"
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
echo "ok - a complete authoritative multi-platform candidate advances"
test_candidate_platform_mismatch_waits
echo "ok - missing and unexpected candidate platforms keep a release pending"
test_current_platform_mismatch_is_an_error
echo "ok - a current tag that violates authoritative platform policy fails"
test_duplicate_canonical_platform_is_an_error
echo "ok - duplicate canonical Docker platforms fail without mutation"
test_schema_one_migrates_legacy_platforms_once
echo "ok - schema one migrates legacy tags once and schema two remains stable"
test_authoritative_policy_can_remove_a_platform
echo "ok - authoritative metadata permits intentional platform removal"
test_invalid_official_metadata_and_state_are_rejected
echo "ok - unknown or duplicate platform policy and invalid state are rejected"
test_candidate_without_official_metadata_waits
echo "ok - candidates cannot advance before authoritative metadata is published"
