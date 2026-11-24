#!/usr/bin/env bash
set -euo pipefail

# GitHub-hosted ubuntu-latest x86_64 runner. The digest is from the upstream release asset.
version=v0.22.1
sha256=0ab7a1d6932a213aed964ce97666c3077fe691c8606413674a8b3e0b9ec4cda0
destination="$RUNNER_TEMP/crane-bin"
archive="$RUNNER_TEMP/go-containerregistry.tar.gz"

mkdir -p "$destination"
curl --fail --silent --show-error --location --retry 3 --output "$archive" \
	"https://github.com/google/go-containerregistry/releases/download/$version/go-containerregistry_Linux_x86_64.tar.gz"
printf '%s  %s\n' "$sha256" "$archive" | sha256sum --check
tar --no-same-owner -xzf "$archive" -C "$destination" crane
printf '%s\n' "$destination" >> "$GITHUB_PATH"
