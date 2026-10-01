#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
REPO_ROOT="$(realpath "$TEST_DIR/../..")"
DETECTOR="$REPO_ROOT/src/bin/check-joomla-releases.sh"
FIXTURES="$TEST_DIR/fixtures"
TEST_TMP="$(mktemp -d)"
CURRENT_TAG="4.4.14-php8.1-apache"
CANDIDATE_TAG="4.4.15-php8.1-apache"
trap 'rm -rf -- "$TEST_TMP"' EXIT

fail() {
	echo "not ok - $*" >&2
	exit 1
}

assert_json_value() {
	local actual
	actual="$(jq -r "$2" "$1")"
	[[ "$actual" == "$3" ]] || fail "$2: expected '$3', got '$actual'"
}

assert_output() {
	grep -Fqx "$2" "$1/github-output" || fail "missing output $2"
}

prepare_case() {
	local case_dir="$TEST_TMP/$1"
	mkdir -p "$case_dir/registry"
	cp "$FIXTURES/versions-multi-platform.json" "$case_dir/versions.json"
	cp "$FIXTURES/upstream-images-multi-platform.json" "$case_dir/upstream-images.json"
	cp "$FIXTURES/registry-index.json" "$case_dir/registry/$CURRENT_TAG.json"
	printf '%s\n' "$case_dir"
}

run_detector() {
	local case_dir="$1"
	shift
	PATH="$TEST_DIR/mocks:$PATH" \
		MOCK_REGISTRY_DIR="$case_dir/registry" \
		GITHUB_OUTPUT="$case_dir/github-output" \
		"$DETECTOR" --quiet \
		--versions-file "$case_dir/versions.json" \
		--state-file "$case_dir/upstream-images.json" "$@"
}

assert_failure_without_mutation() {
	local case_dir="$1"
	shift
	cp "$case_dir/versions.json" "$case_dir/versions.before"
	cp "$case_dir/upstream-images.json" "$case_dir/upstream-images.before"
	if run_detector "$case_dir" "$@" > "$case_dir/stdout" 2> "$case_dir/stderr"; then
		fail "$(basename "$case_dir") succeeded"
	fi
	cmp -s "$case_dir/versions.before" "$case_dir/versions.json" || fail "failed request changed versions"
	cmp -s "$case_dir/upstream-images.before" "$case_dir/upstream-images.json" || fail "failed request changed digest state"
	[[ ! -e "$case_dir/github-output" ]] || fail "failed request emitted success outputs"
}

test_registry_index_types_and_attestations() {
	local media_type
	local case_dir
	local expected_digest
	for media_type in oci docker; do
		case_dir="$(prepare_case "$media_type-index")"
		if [[ "$media_type" == "docker" ]]; then
			jq '.mediaType = "application/vnd.docker.distribution.manifest.list.v2+json" |
				.manifests[].mediaType = "application/vnd.docker.distribution.manifest.v2+json"' \
				"$case_dir/registry/$CURRENT_TAG.json" > "$case_dir/registry/index.tmp"
			mv "$case_dir/registry/index.tmp" "$case_dir/registry/$CURRENT_TAG.json"
		fi
		expected_digest="sha256:$(sha256sum "$case_dir/registry/$CURRENT_TAG.json" | cut -d ' ' -f 1)"
		run_detector "$case_dir" --refresh-current
		assert_json_value "$case_dir/upstream-images.json" \
			".tags[\"$CURRENT_TAG\"].index_digest" "$expected_digest"
		assert_json_value "$case_dir/upstream-images.json" \
			".tags[\"$CURRENT_TAG\"].platforms | keys | join(\",\")" "linux/amd64,linux/arm64/v8"
		assert_json_value "$case_dir/upstream-images.json" \
			".tags[\"$CURRENT_TAG\"].platforms[\"linux/amd64\"]" \
			"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
		assert_output "$case_dir" "versions_changed=no"
		assert_output "$case_dir" "digests_changed=yes"
		[[ "$(wc -l < "$case_dir/registry/requests.log")" == "2" ]] || fail "refresh-current fetched unrelated upstream data"
		cp "$case_dir/upstream-images.json" "$case_dir/upstream-images.before"
		rm "$case_dir/github-output"
		run_detector "$case_dir" --refresh-current
		cmp -s "$case_dir/upstream-images.before" "$case_dir/upstream-images.json" || fail "verified index caused state churn"
		assert_output "$case_dir" "changed=no"
	done
}

test_registry_platform_variants_match_builder_names() {
	local case_dir
	case_dir="$(prepare_case registry-platform-variants)"
	jq '.manifests[0].platform.variant = "v1" |
		.manifests += [{
			mediaType: "application/vnd.oci.image.manifest.v1+json",
			digest: "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
			size: 512,
			platform: {os: "linux", architecture: "arm", variant: "v8"}
		}]' "$case_dir/registry/$CURRENT_TAG.json" > "$case_dir/registry/index.tmp"
	mv "$case_dir/registry/index.tmp" "$case_dir/registry/$CURRENT_TAG.json"
	run_detector "$case_dir" --refresh-current
	assert_json_value "$case_dir/upstream-images.json" \
		".tags[\"$CURRENT_TAG\"].platforms | keys | join(\",\")" \
		"linux/amd64,linux/arm/v8,linux/arm64/v8"
}

test_registry_index_rejects_unverified_content() {
	local invalid_kind
	local case_dir
	local index
	local filter
	for invalid_kind in digest-mismatch missing-digest bad-digest-header malformed-json \
		wrong-schema single-manifest bad-descriptor-digest bad-size bad-platform \
		bad-arm-variant missing-platform duplicate-platform alias-duplicate-platform no-runnable-platform; do
		case_dir="$(prepare_case "invalid-$invalid_kind")"
		index="$case_dir/registry/$CURRENT_TAG.json"
		filter=""
		case "$invalid_kind" in
			digest-mismatch)
				printf '%s\n' 'sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd' > "$case_dir/registry/$CURRENT_TAG.digest"
				;;
			missing-digest) touch "$case_dir/registry/$CURRENT_TAG.no-digest" ;;
			bad-digest-header) printf '%s\n' 'sha256:not-a-digest' > "$case_dir/registry/$CURRENT_TAG.digest" ;;
			malformed-json) printf '%s\n' '{' > "$index" ;;
			wrong-schema) filter='.schemaVersion = 1' ;;
			single-manifest) filter='.mediaType = "application/vnd.oci.image.manifest.v1+json"' ;;
			bad-descriptor-digest) filter='.manifests[0].digest = "sha256:invalid"' ;;
			bad-size) filter='.manifests[0].size = -1' ;;
			bad-platform) filter='.manifests[0].platform.architecture = "invalid/architecture"' ;;
			bad-arm-variant) filter='.manifests[1].platform.variant = "invalid"' ;;
			missing-platform) filter='del(.manifests[0].platform)' ;;
			duplicate-platform) filter='.manifests += [.manifests[0]]' ;;
			alias-duplicate-platform) filter='.manifests += [.manifests[0] | .platform.variant = "v1"]' ;;
			no-runnable-platform) filter='.manifests |= map(select(.platform.os == "unknown"))' ;;
		esac
		if [[ -n "$filter" ]]; then
			jq "$filter" "$index" > "$case_dir/registry/index.tmp"
			mv "$case_dir/registry/index.tmp" "$index"
		fi
		assert_failure_without_mutation "$case_dir" --refresh-current
	done
}

test_registry_transport_failures_are_not_missing_tags() {
	local failure
	local case_dir
	for failure in 401 429 500 network; do
		case_dir="$(prepare_case "candidate-$failure")"
		cp "$FIXTURES/registry-index.json" "$case_dir/registry/$CANDIDATE_TAG.json"
		if [[ "$failure" == "network" ]]; then
			printf '%s\n' '000' > "$case_dir/registry/$CANDIDATE_TAG.status"
			printf '%s\n' '28' > "$case_dir/registry/$CANDIDATE_TAG.exit"
		else
			printf '%s\n' "$failure" > "$case_dir/registry/$CANDIDATE_TAG.status"
		fi
		assert_failure_without_mutation "$case_dir" --releases-file "$FIXTURES/releases-multi-platform-new.json"
		grep -Fq "$failure" "$case_dir/stderr" || {
			[[ "$failure" == "network" ]] && grep -Fq '28' "$case_dir/stderr"
		} || fail "transport error diagnostics omitted the upstream status"
	done
}

test_missing_registry_tag_handling() {
	local case_dir
	case_dir="$(prepare_case candidate-404)"
	run_detector "$case_dir" --releases-file "$FIXTURES/releases-multi-platform-new.json"
	assert_json_value "$case_dir/versions.json" '.["4"].joomla' "4.4.14"
	assert_output "$case_dir" "waiting_majors=4"
	assert_output "$case_dir" "versions_changed=no"
	assert_output "$case_dir" "digests_changed=yes"
	assert_json_value "$case_dir/upstream-images.json" '.tags | keys | join(",")' "$CURRENT_TAG"

	case_dir="$(prepare_case current-404)"
	rm "$case_dir/registry/$CURRENT_TAG.json"
	assert_failure_without_mutation "$case_dir" --refresh-current
}

test_registry_candidate_does_not_invent_unpublished_platforms() {
	local case_dir
	case_dir="$(prepare_case published-platforms)"
	cp "$FIXTURES/registry-index.json" "$case_dir/registry/$CANDIDATE_TAG.json"
	# Planned riscv64 exists in official-images metadata, but is not published.
	printf '%s\n' "Tags: $CANDIDATE_TAG" 'Architectures: amd64, arm64v8, riscv64' > "$case_dir/official-images.txt"
	run_detector "$case_dir" \
		--releases-file "$FIXTURES/releases-multi-platform-new.json" \
		--official-images-file "$case_dir/official-images.txt"
	assert_json_value "$case_dir/versions.json" '.["4"].joomla' "4.4.15"
	assert_json_value "$case_dir/upstream-images.json" \
		".tags[\"$CANDIDATE_TAG\"].platforms | keys | join(\",\")" "linux/amd64,linux/arm64/v8"
	assert_output "$case_dir" "updated_majors=4"
	assert_output "$case_dir" "waiting_majors="
	[[ "$(grep -c '^https://auth.docker.io/' "$case_dir/registry/requests.log")" == "1" ]] || fail "registry token was fetched per tag"
}

test_registry_token_validation() {
	local token_case
	local case_dir
	for token_case in invalid unauthorized access-token; do
		case_dir="$(prepare_case "token-$token_case")"
		case "$token_case" in
			invalid) printf '%s\n' '{"token":""}' > "$case_dir/registry/token.json" ;;
			unauthorized) printf '%s\n' '401' > "$case_dir/registry/token.status" ;;
			access-token) printf '%s\n' '{"access_token":"registry-test-token"}' > "$case_dir/registry/token.json" ;;
		esac
		if [[ "$token_case" == "access-token" ]]; then
			run_detector "$case_dir" --refresh-current
			assert_output "$case_dir" "digests_changed=yes"
		else
			assert_failure_without_mutation "$case_dir" --refresh-current
			[[ "$(wc -l < "$case_dir/registry/requests.log")" == "1" ]] || fail "invalid authentication fetched a manifest"
		fi
	done
}

test_registry_index_types_and_attestations
echo "ok - OCI indexes and Docker lists are byte-verified, attestation-filtered, and stable"
test_registry_platform_variants_match_builder_names
echo "ok - OCI AMD64 v1 uses the builder key and ARM v8 retains its architecture"
test_registry_index_rejects_unverified_content
echo "ok - mismatched digests, invalid index data, and invalid platforms fail without mutation"
test_registry_transport_failures_are_not_missing_tags
echo "ok - authentication, throttling, server, and network errors cannot masquerade as pending tags"
test_missing_registry_tag_handling
echo "ok - registry 404 waits for candidates and fails for configured tags"
test_registry_candidate_does_not_invent_unpublished_platforms
echo "ok - registry publication, independent of planned riscv64, controls candidate readiness"
test_registry_token_validation
echo "ok - registry authentication is validated and supports token/access_token"
