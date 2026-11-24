#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cd "$work"
mkdir -p src/bin conf mocks
cp "$root/src/bin/recover-defaults.sh" src/bin/
git init -q
repo=octoleo/joomengine
export RECOVERY_REGISTRY="$work/registry"
export PATH="$work/mocks:$PATH"

cat > mocks/crane <<'SH'
#!/usr/bin/env bash
set -eu
[[ $# == 2 && $1 == digest ]]
if ! awk -v ref="$2" '$1 == ref {print $2; found=1} END {exit !found}' "$RECOVERY_REGISTRY"; then
	echo "${MOCK_DIGEST_ERROR:-registry unavailable}" >&2
	exit 1
fi
SH
chmod +x mocks/crane
cat > conf/build.json <<'JSON'
{"image":"octoleo/joomengine","publishLast":["latest-mcp-dev","latest-dev","latest-mcp","latest"]}
JSON
stamp=2026-11-24T08:05:58.9840593Z
printf '%s\n' '# publish-last' > expected
for suffix in -mcp-dev -dev -mcp ''; do
	alias="latest${suffix}"
	base="6.2.1-php8.5-apache${suffix}"
	old="6.2.0-php8.5-apache${suffix}"
	digest="sha256:$(printf %s "$base" | sha256sum | cut -d' ' -f1)"
	previous="sha256:$(printf %s "$old" | sha256sum | cut -d' ' -f1)"
	jq -nc --arg image "$repo" --arg base "$old" --arg tag "$alias" \
		'{image:$image,base_tag:$base,tags:[$base,$tag]}' >> conf/manifest.ndjson
	jq -nc --arg image "$repo" --arg base "$base" --arg tag "$alias" \
		'{image:$image,base_tag:$base,tags:[$base,$tag]}' >> candidate
	printf '%s   ↪ Pushed multi-platform image %s:%s\n' "$stamp" "$repo" "$base" >> job.log
	printf '%s   ↪ Verified registry platforms for %s@%s\n' "$stamp" "$repo" "$digest" >> job.log
	printf '%s:%s %s\n' "$repo" "$base" "$digest" "$repo" "$old" "$previous" \
		"$repo" "$alias" "$previous" >> registry
	printf '%s:%s\t%s@%s\n' "$repo" "$alias" "$repo" "$digest" >> expected
done
git add conf
git -c user.name=Test -c user.email=test@example.com commit -qm 'Published previous defaults'
cp candidate conf/manifest.ndjson

./src/bin/recover-defaults.sh job.log plan
cmp expected plan
rm plan
echo 'ok - historical verified indexes recover the current configured defaults in order'

reject() {
	if ./src/bin/recover-defaults.sh "$1" plan >/dev/null 2>&1; then
		echo "Failed to reject $2" >&2
		exit 1
	fi
	[[ ! -e plan ]] || { echo "Partial recovery plan emitted for $2" >&2; exit 1; }
}

head -n -1 job.log > truncated.log
reject truncated.log 'unverified final source'
sed 's/@sha256:/@sha256:invalid/' job.log > invalid.log
reject invalid.log 'malformed source digests'
sed 's/for octoleo/for foreign/' job.log > wrong.log
reject wrong.log 'cross-repository verification'
cat job.log job.log > ambiguous.log
reject ambiguous.log 'ambiguous reports'
sed '/Pushed/a unrelated registry operation' job.log > detached.log
reject detached.log 'non-adjacent verification'
cp registry registry.good
sed -i "s|^$repo:6.2.1-php8.5-apache .*|$repo:6.2.1-php8.5-apache $previous|" registry
reject job.log 'newer versioned index'
cp registry.good registry
sed -i "s|^$repo:latest .*|$repo:latest sha256:$(printf '%064d' 0)|" registry
reject job.log 'latest moved to another release'
cp registry.good registry
sed -i '/:latest /d' registry
reject job.log 'unreadable live default'
MOCK_DIGEST_ERROR='MANIFEST_UNKNOWN: manifest unknown' ./src/bin/recover-defaults.sh job.log plan
cmp expected plan
rm plan
cp registry.good registry
sed 's/6\.2\.1/6.2.2/g' candidate > conf/manifest.ndjson
reject job.log 'newer selected stable release'
echo 'ok - stale and incomplete jobs fail without partial recovery plans'
