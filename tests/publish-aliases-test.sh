#!/usr/bin/env bash
set -euo pipefail

publisher="$(dirname "$0")/../src/bin/publish-aliases.sh"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
export REGISTRY="$work/registry"
export PATH="$work/bin:$PATH"
mkdir -p "$REGISTRY" "$work/bin"
repo=octoleo/joomengine
digest="sha256:$(printf 'a%.0s' {1..64})"
old_digest="sha256:$(printf 'b%.0s' {1..64})"
export old_digest

cat > "$work/bin/crane" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$REGISTRY/trace"
case "$1" in
	digest)
		tag=${2##*:}
		if [[ -f $REGISTRY/failure ]]; then
			cat "$REGISTRY/failure" >&2
			exit 1
		fi
		if [[ -e $REGISTRY/throttle_read ]]; then
			rm "$REGISTRY/throttle_read"
			echo 'Error: TOOMANYREQUESTS: too many requests' >&2
			exit 1
		fi
		if [[ -f $REGISTRY/tag-$tag ]]; then
			echo 'HEAD request failed, falling back on GET' >&2
			cat "$REGISTRY/tag-$tag"
		else
			echo 'HEAD request failed: unexpected status code 404 Not Found' >&2
			echo 'Error: GET /manifests/tag: MANIFEST_UNKNOWN: manifest unknown' >&2
			exit 1
		fi
		;;
	tag)
		if [[ -e $REGISTRY/throttle_write ]]; then
			rm "$REGISTRY/throttle_write"
			echo 'Error: PUT /manifests/tag: unexpected status code 429 Too Many Requests' >&2
			echo 'Retry-After: 90' >&2
			exit 1
		fi
		value=${2##*@}
		if [[ -e $REGISTRY/wrong_write ]]; then value=$old_digest; fi
		printf '%s\n' "$value" > "$REGISTRY/tag-$3"
		;;
	*) exit 2 ;;
esac
MOCK
cat > "$work/bin/sleep" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$REGISTRY/sleeps"
MOCK
chmod +x "$work/bin/crane" "$work/bin/sleep"

plan="$work/plan.tsv"
trace="$REGISTRY/trace"
fail() { echo "not ok - $*" >&2; exit 1; }
run() { "$publisher" "$plan" >"$work/log" 2>&1; }
expect_failure() { if run; then fail 'unexpected publisher success'; fi; }
row() { printf '%s:%s\t%s@%s\n' "$repo" "$1" "$repo" "$digest"; }

: > "$plan"
run
[[ ! -e $trace ]] || fail 'empty plan contacted registry'
{ row current; row missing; row latest; } > "$plan"
printf '%s\n' "$digest" > "$REGISTRY/tag-current"
printf '%s\n' "$old_digest" > "$REGISTRY/tag-latest"
run
cat > "$work/expected" <<TRACE
digest $repo:current
digest $repo:missing
tag $repo@$digest missing
digest $repo:missing
digest $repo:latest
tag $repo@$digest latest
digest $repo:latest
TRACE
diff -u "$work/expected" "$trace"
: > "$trace"
run
[[ $(wc -l < "$trace") == 3 ]] || fail 'unexpected registry operations on resume'
! grep -q '^tag ' "$trace" || fail 'resume repeated a write'

# Other tags can change while defaults still point to the desired digests.
# The configured tail must still be written in order, with plain latest last.
printf '%s\n' "$digest" > "$REGISTRY/tag-latest-dev"
{ row older; printf '# publish-last\n'; row latest-dev; row latest; } > "$plan"
: > "$trace"
run
cat > "$work/expected" <<TRACE
digest $repo:older
tag $repo@$digest older
digest $repo:older
tag $repo@$digest latest-dev
digest $repo:latest-dev
tag $repo@$digest latest
digest $repo:latest
TRACE
diff -u "$work/expected" "$trace"

row new > "$plan"
: > "$trace"
: > "$REGISTRY/throttle_read"
: > "$REGISTRY/throttle_write"
run
diff -u <(printf '15\n90\n') "$REGISTRY/sleeps"
[[ $(<"$REGISTRY/tag-new") == "$digest" ]] || fail 'retry did not publish expected index'

: > "$trace"
: > "$REGISTRY/sleeps"
printf '%s\n' 'Error: status code 429 Too Many Requests' > "$REGISTRY/failure"
expect_failure
diff -u <(printf '15\n30\n60\n120\n') "$REGISTRY/sleeps"
[[ $(wc -l < "$trace") == 5 ]] || fail 'retry count'

echo 'Retry-After: 1800' >> "$REGISTRY/failure"
: > "$REGISTRY/sleeps"
expect_failure
[[ ! -s $REGISTRY/sleeps ]] || fail 'retried earlier than Retry-After'

for error in 'UNAUTHORIZED: denied' 'connection reset by peer' 'unexpected status code 404 Not Found'; do
	: > "$trace"
	printf 'HEAD request failed: MANIFEST_UNKNOWN: missing\nError: GET /manifests/new: %s\n' "$error" > "$REGISTRY/failure"
	expect_failure
	[[ $(<"$trace") == "digest $repo:new" ]] || fail 'unsafe write after failed read'
done
rm "$REGISTRY/failure"

: > "$trace"
printf 'invalid-digest\n' > "$REGISTRY/tag-new"
expect_failure
! grep -q '^tag ' "$trace" || fail 'unsafe write after invalid digest'
rm "$REGISTRY/tag-new"
: > "$REGISTRY/wrong_write"
{ row new; row later; } > "$plan"
expect_failure
grep -q 'Digest mismatch' "$work/log" || fail 'did not report verification failure'
[[ ! -e $REGISTRY/tag-later ]] || fail 'continued after verification failure'

for invalid in "$repo:latest"$'\t'"other/repo@$digest" "$repo:latest"$'\t'"$repo:source"; do
	: > "$trace"
	printf '%s\n' "$invalid" > "$plan"
	expect_failure
	[[ ! -s $trace ]] || fail 'invalid plan contacted registry'
done
printf 'ok - verified, resumable alias publication\n'
