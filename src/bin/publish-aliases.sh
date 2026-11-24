#!/usr/bin/env bash
set -euo pipefail

# Each TSV row maps a destination tag to a verified index digest in the same repository.
# The optional "# publish-last" line begins the ordered tail selected by conf/build.json.
if [[ $# != 1 || ! -f $1 || ! -r $1 ]]; then
	echo "Usage: ${0##*/} PLAN.tsv" >&2
	exit 1
fi
[[ -s $1 ]] || exit 0
command -v crane >/dev/null || { echo 'crane is required for alias publication' >&2; exit 1; }

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

# crane uses the existing Docker credential configuration. Keep its warnings separate
# from stdout: a successful digest lookup can include a HEAD-to-GET fallback warning.
registry_call() {
	local attempt=1 backoff=15 delay final_error retry_after retry_time
	while true; do
		if crane "$@" >"$tmp_dir/result" 2>"$tmp_dir/error"; then
			return 0
		fi
		# Only the final failure describes the outcome of a fallback GET. A failed
		# HEAD on its own is insufficient evidence that the tag is absent.
		final_error=$(awk 'NF && tolower($0) !~ /^[[:space:]]*retry-after:/ { error=$0 } END { print error }' "$tmp_dir/error")
		if [[ $1 == digest && $final_error =~ (^|[[:space:]])MANIFEST_UNKNOWN(:|$) ]]; then
			return 2
		fi
		cat "$tmp_dir/error" >&2
		if ! [[ $final_error =~ (^|[^[:alnum:]])(429|TOOMANYREQUESTS)([^[:alnum:]]|$) ]] || (( attempt >= 5 )); then
			return 1
		fi
		delay=$backoff
		retry_after=$(sed -nE 's/.*[Rr][Ee][Tt][Rr][Yy]-[Aa][Ff][Tt][Ee][Rr]:[[:space:]]*([^;]+).*/\1/p' "$tmp_dir/error" | tail -n 1 | tr -d '\r')
		if [[ -n $retry_after ]]; then
			if [[ $retry_after =~ ^[0-9]+$ ]]; then
				# A long wait belongs in a later run. Never retry sooner than requested.
				if (( ${#retry_after} > 8 )); then return 1; fi
				retry_time=$((10#$retry_after))
			elif retry_time=$(LC_ALL=C date -u -d "$retry_after" +%s 2>/dev/null); then
				retry_time=$(( retry_time - $(date +%s) ))
			else
				retry_time=0
			fi
			if (( retry_time > 300 )); then
				echo 'Registry requested a wait over five minutes. Resume publication later.' >&2
				return 1
			fi
			if (( retry_time > delay )); then delay=$retry_time; fi
		fi
		printf 'Registry throttled crane %s. Retrying in %ss (%d/5).\n' "$1" "$delay" "$((attempt + 1))" >&2
		sleep "$delay"
		attempt=$((attempt + 1))
		backoff=$((backoff * 2))
	done
}

repo_pattern='[[:alnum:]][^[:space:]@]*'
row_pattern="^($repo_pattern):([A-Za-z0-9_][A-Za-z0-9_.-]{0,127})"$'\t'"($repo_pattern)@(sha256:[0-9a-f]{64})$"
publish_last=false
while IFS= read -r row || [[ -n $row ]]; do
	if [[ $row == "# publish-last" ]]; then
		publish_last=true
		continue
	fi
	if ! [[ $row =~ $row_pattern ]] || [[ ${BASH_REMATCH[1]} != "${BASH_REMATCH[3]}" ]]; then
		echo "Invalid same-repository alias mapping: $row" >&2
		exit 1
	fi
	repository=${BASH_REMATCH[1]} tag=${BASH_REMATCH[2]} digest=${BASH_REMATCH[4]}
	target="$repository:$tag"
	# Re-tag configured defaults even if a previous run stopped partway through
	# publication. Their last-write order is part of the publication policy.
	if [[ $publish_last == false ]]; then
		if registry_call digest "$target"; then
			current=$(<"$tmp_dir/result")
			[[ $current =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "Invalid registry digest for $target: $current" >&2; exit 1; }
			if [[ $current == "$digest" ]]; then
				printf 'Already published %s\n' "$target"
				continue
			fi
		elif [[ $? != 2 ]]; then
			exit 1
		fi
	fi

	# All referenced blobs and child manifests are already present in this repository.
	registry_call tag "$repository@$digest" "$tag"
	registry_call digest "$target" || { echo "Unable to verify $target after publishing" >&2; exit 1; }
	current=$(<"$tmp_dir/result")
	if [[ $current != "$digest" ]]; then
		echo "Digest mismatch for $target: expected $digest, got $current" >&2
		exit 1
	fi
	printf 'Published %s at %s\n' "$target" "$digest"
done < "$1"
