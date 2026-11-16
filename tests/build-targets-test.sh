#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=src/lib/build-targets.sh
source "$root/src/lib/build-targets.sh"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
config="$temporary/versions.json"
build="$root/conf/build.json"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
reject() {
	if build_targets_normalize "$config" "$build" > "$temporary/result.json" 2>/dev/null; then
		fail "$1"
	fi
	[[ ! -s "$temporary/result.json" ]] || fail 'Invalid configuration emitted partial JSON'
}

cat > "$config" <<'JSON'
{"6":{"joomla":"6.2.0","php":["8.5"],"variants":["apache"]}}
JSON
build_targets_normalize "$config" "$build" > "$temporary/legacy.json"
jq -e '."6" | .channel == "stable" and .update == "stable" and .tags == "default" and .jcb.major == "6" and .jcb.versions == "all" and .profiles == ["standard"]' "$temporary/legacy.json" >/dev/null || fail 'Legacy numeric matrix changed meaning'
echo 'ok - legacy matrix normalizes to explicit stable targets'

jq '."6" as $stable | . + {
	"joomla7-alpha": ($stable + {joomla:"7.0.0-alpha1",channel:"alpha",update:"pinned",tags:"qualified",jcb:{major:"6",versions:"latest-stable"},profiles:["standard","dev"]}),
	"jcb-rc": ($stable + {tags:"qualified",jcb:{major:"6",versions:"latest-rc"}}),
	"joomla6-beta": ($stable + {joomla:"6.3.0-beta2",channel:"beta",update:"pinned",tags:"qualified",jcb:{major:"6",versions:["6.2.0"]}}),
	"joomla6-rc": ($stable + {joomla:"6.3.0-rc1",channel:"rc",update:"pinned",tags:"qualified",jcb:{major:"6",versions:["6.2.0","6.2.1-alpha2"]}})
}' "$temporary/legacy.json" > "$config"
build_targets_normalize "$config" "$build" > "$temporary/valid.json"
jq -e 'length == 5 and ."joomla7-alpha".jcb.major == "6" and ."jcb-rc".channel == "stable" and ."jcb-rc".jcb.versions == "latest-rc"' "$temporary/valid.json" >/dev/null || fail 'Independent Joomla and JCB selection failed'
echo 'ok - Joomla and JCB release channels are independent'

for selector in latest-alpha latest-beta latest-rc latest-stable all; do
	jq --arg selector "$selector" '."jcb-rc".jcb.versions = $selector' "$temporary/valid.json" > "$config"
	build_targets_normalize "$config" "$build" >/dev/null || fail "JCB selector $selector rejected"
done
jq '.future = (."6" + {enabled:false,joomla:"8.0.0-alpha1",channel:"alpha",update:"pinned",tags:"qualified",jcb:{major:"8",versions:"latest-alpha"}})' "$temporary/valid.json" > "$config"
build_targets_normalize "$config" "$build" | jq -e 'has("future") | not' >/dev/null || fail 'Disabled target was activated'
echo 'ok - release selectors and disabled future targets are understood'

for mutation in \
	'."joomla7-alpha".channel = "stable"' \
	'."joomla7-alpha".update = "stable"' \
	'."joomla7-alpha".tags = "default"' \
	'."joomla7-alpha".joomla = "7.0.0-alpha0"' \
	'."joomla7-alpha".jcb.versions = ["7.0.0"]' \
	'."joomla7-alpha".jcb.versions = []' \
	'."joomla7-alpha".jcb.versions = "latest"' \
	'."joomla7-alpha".profiles = ["missing"]' \
	'."joomla7-alpha".php = ["8.5","8.5"]' \
	'."joomla7-alpha".typo = true' \
	'.duplicate = ."6"' \
	'with_entries(.value.enabled = false)'; do
	jq "$mutation" "$temporary/valid.json" > "$config"
	reject "Invalid target accepted: $mutation"
done
echo 'ok - invalid or ambiguous build targets fail without partial output'
