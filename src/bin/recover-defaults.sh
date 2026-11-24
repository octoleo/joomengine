#!/usr/bin/env bash
set -euo pipefail

# The workflow authenticates the source job, refreshes the manifest with --dry-run
# and holds the normal publication lock for both planning and applying these tags.
if [[ $# != 2 || ! -r $1 ]]; then
	echo "Usage: ${0##*/} VERIFIED_JOB.log OUTPUT.tsv" >&2
	exit 1
fi

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d -- "$(dirname "$2")/.recover-defaults.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT

repository=$(jq -er '.image' "$root/conf/build.json")
git -C "$root" show HEAD:conf/manifest.ndjson > "$work/previous.ndjson"

# Require adjacent, timestamped messages printed by the build engine. Later
# platform checks for old alias sources do not attest to a newly built image.
awk -v repo="$repository" '
	$1 ~ /^[0-9][0-9][0-9][0-9]-/ && $2 == "↪" {
		if (NF == 6 && $3 == "Pushed" && $4 == "multi-platform" &&
		    $5 == "image" && index($6, repo ":") == 1) {
			tag = substr($6, length(repo) + 2)
			pushed = NR
		} else if (NR == pushed + 1 && NF == 7 && $3 == "Verified" &&
		           $4 == "registry" && $5 == "platforms" && $6 == "for" &&
		           index($7, repo "@sha256:") == 1) {
			print tag "\t" substr($7, length(repo) + 2)
		}
	}
' "$1" > "$work/receipts.tsv"

jq -ers --arg repo "$repository" --slurpfile previous "$work/previous.ndjson" \
	--slurpfile config "$root/conf/build.json" '
	def owner($records; $tag):
		[$records[] | select(.image == $repo and (.tags | index($tag))) | .base_tag]
		| if length > 1 then error("Ambiguous owner of " + $tag) else .[0] end;
	. as $current | $config[0].publishLast[] as $tag |
	[ $tag, (owner($current; $tag) // error("No current owner for " + $tag)),
	  (owner($previous; $tag) // "") ] | @tsv
' "$root/conf/manifest.ndjson" > "$work/owners.tsv"

printf '%s\n' '# publish-last' > "$work/plan.tsv"
while IFS=$'\t' read -r alias base previous; do
	digest=$(awk -F '\t' -v base="$base" '$1 == base { print $2 }' "$work/receipts.tsv")
	if ! [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]]; then
		echo "Missing or ambiguous verified build for $repository:$base" >&2
		exit 1
	fi
	if [[ $(crane digest "$repository:$base") != "$digest" ]]; then
		echo "The published source $repository:$base has changed since the job" >&2
		exit 1
	fi

	# A later release can leave the versioned source intact. Recover only a
	# default which still names the last committed release or the requested one.
	if ! current=$(crane digest "$repository:$alias" 2>"$work/error"); then
		# A confirmed missing default can be created. An auth or transport
		# failure leaves its current release unknown and must stop recovery.
		if ! awk 'NF { last=$0 } END { exit !(last ~ /(^|[[:space:]])MANIFEST_UNKNOWN(:|$)/) }' "$work/error"; then
			cat "$work/error" >&2
			exit 1
		fi
		current=""
	elif ! [[ $current =~ ^sha256:[0-9a-f]{64}$ ]]; then
		echo "Invalid registry digest for $repository:$alias" >&2
		exit 1
	fi
	if [[ -n $current && $current != "$digest" ]]; then
		if [[ -z $previous ]]; then
			echo "No recorded previous owner for $repository:$alias" >&2
			exit 1
		fi
		previous_digest=$(crane digest "$repository:$previous")
		if ! [[ $previous_digest =~ ^sha256:[0-9a-f]{64}$ && $current == "$previous_digest" ]]; then
			echo "The current $repository:$alias differs from the recorded release" >&2
			exit 1
		fi
	fi
	printf '%s:%s\t%s@%s\n' "$repository" "$alias" "$repository" "$digest" >> "$work/plan.tsv"
done < "$work/owners.tsv"

mv -- "$work/plan.tsv" "$2"
