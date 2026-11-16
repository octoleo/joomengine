#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TMP"' EXIT
# shellcheck source=../src/lib/image-config.sh
source "$REPO_ROOT/src/lib/image-config.sh"

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
assert_status() {
	local expected="$1" actual=0
	shift
	"$@" > "$TEST_TMP/output" 2> "$TEST_TMP/error" || actual=$?
	[[ "$actual" == "$expected" ]] || {
		cat "$TEST_TMP/error" >&2
		fail "$* returned $actual, expected $expected"
	}
}
contains() { grep -Fq -- "$2" "$1" || fail "$1 is missing $2"; }

config="$REPO_ROOT/conf/build.json"
maintainers="$REPO_ROOT/conf/maintainers.json"
hash="$(printf 'a%.0s' {1..128})"
digest="sha256:$(printf 'b%.0s' {1..64})"
metadata="$(jq -cn --arg hash "$hash" --arg digest "$digest" '{
	joomla: "6.2.0", php: "8.4", variant: "apache", profile: "dev", base_digest: $digest,
	jcb: {version: "6.2.1-alpha2", url: "https://example.test/releases/jcb.zip?download=1&source=image", sha512: $hash},
	mcp: null
}')"

assert_status 0 image_config_validate "$config" "$maintainers"
[[ "$(image_profile_suffix "$config" standard)" == '' ]] || fail 'standard suffix changed'
[[ "$(image_profile_suffix "$config" dev)" == '-dev' ]] || fail 'dev suffix missing'
assert_status 2 image_profile_suffix "$config" absent

image_render_dockerfile "$config" "$maintainers" "$metadata" > "$TEST_TMP/dev"
image_render_dockerfile "$config" "$maintainers" "$metadata" > "$TEST_TMP/repeated"
cmp -s "$TEST_TMP/dev" "$TEST_TMP/repeated" || fail 'render is not deterministic'
contains "$TEST_TMP/dev" "FROM joomla:6.2.0-php8.4-apache-dev@$digest"
contains "$TEST_TMP/dev" 'ENV JOOMLA_EXTENSIONS_PATHS="/usr/src/joomengine/jcb.zip"'
contains "$TEST_TMP/dev" "ENV JCB_SHA512=\"$hash\""
contains "$TEST_TMP/dev" 'ENV JOOMLA_ADMIN_USERNAME="joomengine"'
contains "$TEST_TMP/dev" 'ENV JCB_PACKAGE="https://example.test/releases/jcb.zip?download=1&source=image"'
contains "$TEST_TMP/dev" 'LABEL org.opencontainers.image.authors="Llewellyn van der Merwe'
contains "$TEST_TMP/dev" '--proto '\''=https'\'' --proto-redir '\''=https'\'''
contains "$TEST_TMP/dev" 'sha512sum -c -'
if grep -Eq '^(COPY|ENTRYPOINT|CMD)[[:space:]]|MCP_PACKAGE|mcp.zip' "$TEST_TMP/dev"; then
	fail 'plain image replaces upstream startup or includes MCP'
fi

for joomla in 4.4.14 5.4.10 6.2.0; do
	php=8.2
	[[ "$joomla" != 6.* ]] || php=8.4
	standard="$(jq -c --arg joomla "$joomla" --arg php "$php" '.joomla = $joomla | .php = $php | .profile = "standard" | .variant = "fpm-alpine"' <<< "$metadata")"
	image_render_dockerfile "$config" "$maintainers" "$standard" > "$TEST_TMP/standard"
	contains "$TEST_TMP/standard" "FROM joomla:$joomla-php$php-fpm-alpine@$digest"
	if grep -Eq '^(COPY|ENTRYPOINT|CMD)[[:space:]]' "$TEST_TMP/standard"; then
		fail 'standard image replaces the upstream entrypoint'
	fi
done
printf 'ok - all image profiles inherit startup and preserve pinned metadata\n'

mcp_metadata="$(jq -c --arg hash "$hash" '.mcp = {version:"1.0.0",url:"https://example.test/mcp.zip",sha512:$hash}' <<< "$metadata")"
image_render_dockerfile "$config" "$maintainers" "$mcp_metadata" > "$TEST_TMP/mcp"
contains "$TEST_TMP/mcp" 'ENV JOOMLA_EXTENSIONS_PATHS="/usr/src/joomengine/jcb.zip;/usr/src/joomengine/mcp.zip"'
contains "$TEST_TMP/mcp" 'LABEL org.joomengine.mcp.version="1.0.0"'
contains "$TEST_TMP/mcp" 'ENV MCP_PACKAGE="https://example.test/mcp.zip"'
contains "$TEST_TMP/mcp" '"$MCP_SHA512" "$JCB_INSTALL_DIR/mcp.zip" | sha512sum -c -'
printf 'ok - MCP images install verified JCB and MCP packages in explicit order\n'

# Dockerfile quoting must preserve literal text without expanding shell variables.
site_name='JCB "quoted" \ path $HOME `literal`'
jq --arg value "$site_name" '.environment.JOOMLA_SITE_NAME = $value' "$config" > "$TEST_TMP/quoted.json"
image_render_dockerfile "$TEST_TMP/quoted.json" "$maintainers" "$metadata" > "$TEST_TMP/quoted"
contains "$TEST_TMP/quoted" 'ENV JOOMLA_SITE_NAME="JCB \"quoted\" \\ path \$HOME `literal`"'
jq -S . "$TEST_TMP/quoted.json" > "$TEST_TMP/sorted.json"
image_render_dockerfile "$TEST_TMP/sorted.json" "$maintainers" "$metadata" > "$TEST_TMP/sorted"
cmp -s "$TEST_TMP/quoted" "$TEST_TMP/sorted" || fail 'JSON object order changes Dockerfile'
printf 'ok - literal quotes, backslashes and dollars survive deterministic rendering\n'

# A configuration can omit the baked password so deployment secrets use the
# upstream JOOMLA_ADMIN_PASSWORD_FILE mechanism without an inline-value conflict.
jq 'del(.environment.JOOMLA_ADMIN_PASSWORD)' "$config" > "$TEST_TMP/password-file.json"
image_render_dockerfile "$TEST_TMP/password-file.json" "$maintainers" "$metadata" > "$TEST_TMP/password-file"
if grep -Eq '^ENV JOOMLA_ADMIN_PASSWORD=' "$TEST_TMP/password-file"; then
	fail 'omitted administrator password was restored during rendering'
fi
contains "$TEST_TMP/password-file" 'ENV JOOMLA_ADMIN_USERNAME="joomengine"'
contains "$TEST_TMP/password-file" 'ENV JOOMLA_SITE_NAME="Joomla Component Builder - JoomEngine"'
contains "$TEST_TMP/password-file" 'ENV JOOMLA_EXTENSIONS_PATHS="/usr/src/joomengine/jcb.zip"'
printf 'ok - configurations can delegate the administrator password to runtime secrets\n'

# Configuration and untrusted release metadata fail before emitting a Dockerfile.
for expression in \
	'.profiles.dev.suffix = "\nRUN false"' \
	'.profiles.dev.suffix = ""' \
	'.defaultProfile = "absent"' \
	'.environment.JOOMLA_ADMIN_EMAIL = "a\nb"' \
	'.environment["BAD\n"] = "value"' \
	'.environment.JCB_PACKAGE = "https://example.test/override.zip"' \
	'.packageDirectory = "/tmp/../var/www/html"' \
	'.sources.joomla_releases_url = "http://example.test/"'; do
	jq "$expression" "$config" > "$TEST_TMP/invalid.json"
	assert_status 2 image_render_dockerfile "$TEST_TMP/invalid.json" "$maintainers" "$metadata"
	[[ ! -s "$TEST_TMP/output" ]] || fail 'invalid config emitted a partial Dockerfile'
done
for expression in \
	'.base_digest = "sha256:bad"' \
	'.variant = "apache\nRUN false"' \
	'.profile = "absent"' \
	'.jcb.sha512 = "bad"' \
	'.joomla += "\n"' \
	'.jcb.sha512 += "\n"' \
	'.jcb.url += "\n"' \
	'.jcb.url = "https://example.test/$(touch-pwned).zip"' \
	'.jcb.url = "https://example.test/\nRUN false"' \
	'.mcp = false' \
	'.mcp = {version:"1.0.0",url:"https://example.test/mcp.zip",sha512:"bad"}'; do
	invalid_metadata="$(jq -c "$expression" <<< "$metadata")"
	assert_status 2 image_render_dockerfile "$config" "$maintainers" "$invalid_metadata"
	[[ ! -s "$TEST_TMP/output" ]] || fail 'invalid metadata emitted a partial Dockerfile'
done
printf '[]\n' > "$TEST_TMP/no-maintainers.json"
assert_status 2 image_config_validate "$config" "$TEST_TMP/no-maintainers.json"
printf 'ok - invalid configuration, metadata and injection attempts fail before rendering\n'

# Run the actual generated package layer with a local download stub. A correct
# archive passes; a corrupted archive must stop at the checksum before ownership.
printf 'the pinned JCB package\n' > "$TEST_TMP/archive.zip"
actual_hash="$(sha512sum "$TEST_TMP/archive.zip" | cut -d' ' -f1)"
export JCB_INSTALL_DIR="$TEST_TMP/packages" JCB_PACKAGE='https://example.test/jcb.zip' JCB_SHA512="$actual_hash"
export IMAGE_CONFIG_ARCHIVE="$TEST_TMP/archive.zip" IMAGE_CONFIG_OWNERSHIP="$TEST_TMP/ownership"
mkdir "$TEST_TMP/bin"
cat > "$TEST_TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
set -eu
while (($#)); do
	if [[ "$1" == --output ]]; then cp "$IMAGE_CONFIG_ARCHIVE" "$2"; exit; fi
	shift
done
exit 1
SH
cat > "$TEST_TMP/bin/chown" <<'SH'
#!/usr/bin/env bash
touch "$IMAGE_CONFIG_OWNERSHIP"
SH
chmod +x "$TEST_TMP/bin/curl" "$TEST_TMP/bin/chown"
awk '/^RUN / {active=1; sub(/^RUN /, "")} active {print; if ($0 !~ /\\$/) exit}' "$TEST_TMP/dev" > "$TEST_TMP/layer.sh"
assert_status 0 env PATH="$TEST_TMP/bin:$PATH" bash "$TEST_TMP/layer.sh"
[[ -f "$TEST_TMP/ownership" ]] || fail 'verified package did not finish the layer'
rm "$TEST_TMP/ownership"
printf 'corrupt\n' >> "$TEST_TMP/archive.zip"
assert_status 1 env PATH="$TEST_TMP/bin:$PATH" bash "$TEST_TMP/layer.sh"
[[ ! -e "$TEST_TMP/ownership" ]] || fail 'bad checksum did not stop the layer'
printf 'ok - generated download layer verifies archive bytes and rejects corruption\n'
