# Joomla Component Builder - Official Docker Images

[![JoomEngine - Build](https://img.shields.io/github/actions/workflow/status/octoleo/joomengine/joomengine.yml?branch=master&style=for-the-badge&logo=githubactions&logoColor=fff&label=build)](https://github.com/octoleo/joomengine/actions/workflows/joomengine.yml)
[![JoomEngine - Quality](https://img.shields.io/github/actions/workflow/status/octoleo/joomengine/quality.yml?branch=master&style=for-the-badge&logo=githubactions&logoColor=fff&label=quality)](https://github.com/octoleo/joomengine/actions/workflows/quality.yml)
[![JoomEngine - Joomla](https://img.shields.io/github/actions/workflow/status/octoleo/joomengine/joomla-release-poll.yml?branch=master&style=for-the-badge&logo=joomla&logoColor=fff&label=joomla)](https://github.com/octoleo/joomengine/actions/workflows/joomla-release-poll.yml)
[![JoomEngine - Docker](https://img.shields.io/docker/pulls/octoleo/joomengine?style=for-the-badge&logo=docker&logoColor=fff&color=005AA4&label=docker.io%20pulls)](https://hub.docker.com/r/octoleo/joomengine)

This repository contains the **official Docker image build system** for
**Joomla Component Builder (JCB)**.

It is the canonical source for generating, tagging, and publishing all
Joomla Component Builder Docker images across supported:

- Joomla versions
- PHP versions
- Runtime variants (Apache / FPM / FPM-ALPINE)
- Linux CPU architectures supplied by each selected official Joomla base image
- Stable and prerelease channels

All images are **generated, versioned, and published automatically** from
authoritative upstream release data.

---

## 🧠 What This Repository Is (and Is Not)

### ✅ What it *is*

- The **official Docker image source** for Joomla Component Builder
- A **fully automated build engine** driven by upstream JCB releases
- A **deterministic and auditable system** that:
  - Tracks release hashes describing what was built
  - Generates Dockerfiles automatically
  - Emits a complete build manifest
  - Builds, tags, and publishes images consistently

### ❌ What it is *not*

- A manually curated set of Dockerfiles
- A place to hand-edit image definitions
- A CI script that hides build logic in YAML

> **All build logic lives in `src/bin/joomengine.sh`.**
> CI only authenticates, runs it, and commits the results.

---

## 📦 Published Images

All images are published to Docker Hub under:

[https://hub.docker.com/r/octoleo/joomengine](https://hub.docker.com/r/octoleo/joomengine)

You can pull images directly, for example:

```bash
docker pull octoleo/joomengine:latest
docker pull octoleo/joomengine:6.1.3
docker pull octoleo/joomengine:6.1.3-php8.3-apache
````

Every tag is a multi-platform Linux image. Docker automatically selects the
matching image for the host, so the same tags work across all architectures
supplied by the selected official Joomla base image; architecture-specific
JoomEngine tags are not required.

[Docker details ->](https://github.com/octoleo/joomengine/blob/master/docker/README.md)

### Optional JoomEngine MCP images

Append `-mcp` to a supported tag to include the JoomEngine MCP package:

```bash
docker pull octoleo/joomengine:6-php8.3-apache-mcp
docker pull octoleo/joomengine:6-mcp
docker pull octoleo/joomengine:latest-mcp
```

Tags without this suffix, including `latest`, contain JCB without MCP. The tag's
leading version identifies JCB; the Joomla base version is recorded in the build
manifest and image labels. Apache, FPM, and FPM-Alpine each receive MCP counterparts
only when their Joomla and PHP versions meet the package's update XML constraints.

The build resolves the highest stable MCP package once from its
[authoritative update XML](https://raw.githubusercontent.com/joomengine/mcp_package/refs/heads/main/.github/joomengine_mcp_update_server.xml).
At introduction, that is package 1.0.1, requiring PHP 8.3.0 and Joomla 6.1+ within
6.x. Joomla 6.0, Joomla 5, and Joomla 7 are not eligible under that XML. Eligibility
is read from the selected release on every build rather than hardcoded to these
current requirements; Joomla versions below 6 never receive MCP variants.

The package version is not another tag dimension. Every `-mcp` tag follows the
latest stable MCP at build time, while the image records the exact version, URL,
and SHA-512. Missing metadata or a failed archive checksum aborts the build.
Container startup uses only the verified local ZIP; it does not fetch releases.
Pin the resulting image digest when a deployment must use identical image bytes.

MCP contexts use a separate `variant-mcp/` directory, manifest row, and successful
build record. MCP metadata changes rebuild MCP images without rebuilding standard
images. The manifest's `flavor` is `standard` or `mcp`; `mcp` holds the selected
package metadata or `null`. The `latest` flag belongs to the standard image, and
`latest_mcp` identifies the MCP counterpart.

---

## 🏗️ How Images Are Built

Image generation is driven entirely by the script:

```
./src/bin/joomengine.sh
```

At a high level, the build engine performs the following steps:

1. **Discovers upstream JCB releases**

   * Fetches official update XML files per major version
   * Extracts version numbers, download URLs, and SHA512 hashes
   * Refuses to build if hashes are missing

2. **Expands build matrices**

   * Joomla major versions
   * Supported PHP versions (per Joomla)
   * Runtime variants (`apache`, `fpm`, `fpm-alpine`)

3. **Generates build contexts**

   * Creates versioned directory trees under `images/`
   * Generates Dockerfiles from templates
   * Injects release metadata as build arguments
   * Copies and configures the Docker entrypoint

4. **Tracks build state**

   * Records JCB hashes, source fingerprints, and verified Joomla base digests
   * Rebuilds only combinations whose effective inputs changed
   * Commits hash state only after every affected image succeeds

5. **Calculates tag leadership**

   * Determines highest stable versions per major
   * Determines global highest stable version
   * Handles prerelease channels (`alpha`, `beta`, `rc`) correctly
   * Ensures **no tag collisions**

6. **Emits a build manifest**

   * Outputs a machine-readable NDJSON manifest (`conf/manifest.ndjson`)
   * Each line describes exactly one buildable image and its tags

7. **Builds and publishes images**

   * Pulls and pins the verified official Joomla base-image digest
   * Automatically builds every Linux platform supplied by that base image
   * Publishes each tag as one multi-platform image index
   * Builds only changed base images
   * Promotes complete multi-platform rolling and `latest` aliases only after all base builds succeed
   * Pushes images to the registry (unless disabled)

---

## 🏷️ Tagging Strategy (Important)

This repository follows a **strict, predictable tagging policy**.

### Base tags (always present)

```
<version>-php<php>-<variant>
```

Example:

```
6.1.3-php8.3-apache
```

---

### Apache shorthand tags

If the variant is `apache`, a shorthand tag is added:

```
<version>-php<php>
```

---

### Highest PHP shorthand

If the PHP version is the **highest supported PHP** for that Joomla major:

```
<version>-<variant>
<version>
```

(when `apache`)

---

### Stable rolling tags (per major)

If a version is the **highest stable release** of its major:

```
<minor>-php<php>-<variant>
<major>-php<php>-<variant>
<minor>-<variant>
<major>-<variant>
<minor>
<major>
```

(variant-dependent)

---

### Global `latest`

Only one image ever receives:

```
latest
```

Criteria:

* Stable release
* Highest version globally
* Apache variant
* Highest supported PHP

---

### Prerelease channels (`alpha`, `beta`, `rc`)

Prereleases are tagged **without polluting stable tags**.

Examples:

```
6.1.4-rc
6.1.4-rc1
6.1.4-rc1-php8.3-apache
```

Rules:

* Numbered prereleases roll forward correctly
* Unnumbered prereleases are treated as "highest in channel"
* Stable tags are never reused for prereleases

---

## 📁 Repository Structure

```
.
├── conf/                           # Declarative data & state
│   ├── versions.json               # Supported Joomla / PHP / variant matrix
│   ├── maintainers.json            # Image maintainer metadata
│   ├── upstream-images.json         # Verified Joomla image-index/platform state
│   ├── hashes.txt                  # Tracks built release combinations
│   └── manifest.ndjson             # (generated) build manifest (NDJSON)
│
├── images/                         # Generated Docker build contexts
│   └── jcbX.Y.Z/                   # (generated) per-jcb-version
│       └── jX.Y.Z/                 # (generated) per-joomla-version
│           └── phpX.Y/             # (generated) per-php-version
│               └── variant/        # (generated) per-variant
│                   └── Dockerfile  # (generated) dockerfile
│                   └── entrypoint  # (generated) entrypoint
│
├── log/                            # Logs folder (gitignored)
│   └── joomengine-tag.log          # (generated) image tagging log (gitignored)
│
├── src/                            # Executable & reusable source
│   ├── bin/
│   │   ├── check-joomla-releases.sh # Stable-release and Docker-tag detector
│   │   └── joomengine.sh           # The build engine (authoritative logic)
│   │
│   └── docker/
│       ├── Dockerfile.template     # Template used to generate Dockerfiles
│       ├── docker-entrypoint.sh    # Runtime entrypoint copied into images
│       ├── jq-template.awk         # jq/awk helpers for manifest rendering (gitignored)
│       └── .gitignore
│
├── docker/                         # Developer-facing Docker usage
│   ├── docker-compose.yml          # Basic example
│   └── README.md                   # How to use these images
│
├── .github/
│   └── workflows/                  # Automation (thin by design)
│       ├── joomla-release-poll.yml # Upstream release/digest polling
│       ├── joomengine.yml           # Changed-image publisher
│       └── quality.yml              # Unit, lint, and image-smoke gates
│
├── tests/                           # Deterministic, network-free test suites
│
├── .editorconfig
├── .gitignore
├── LICENSE
└── README.md                       # Project overview (what / why)
```

> **Do not edit generated image files manually.**
> They are overwritten by `./src/bin/joomengine.sh`.

---

## 🤖 Automation & CI

This repository uses GitHub Actions to run the build engine automatically.

### Release detection

Every six hours, the release poller:

1. Reads Joomla's official stable-release feed
2. Reads every configured PHP × variant index directly from the official `library/joomla` Docker registry and verifies its SHA-256 digest
3. Waits successfully, without a repository change or failed workflow, while any candidate tag is unavailable
4. Atomically updates `conf/versions.json` and `conf/upstream-images.json` only when a complete matrix is ready
5. Checks the latest stable MCP package against eligible images and successful build records
6. Dispatches the normal image publisher when Joomla inputs changed or MCP images need rebuilding

Digest-only changes are deliberate rebuild triggers, so refreshed upstream base
images receive the same verification and publication path as new Joomla releases.

The published registry index defines the available Linux platforms. The poller
verifies the raw index against its `Docker-Content-Digest`, records each runnable
platform's manifest digest, and ignores attestation descriptors. Architectures
listed in `docker-library/official-images` may still be awaiting publication, so
they do not block an otherwise usable tag. Every configured tag must be published;
missing tags, invalid manifests, or digest mismatches cannot become build inputs.
Later platform additions or removals change the saved state and trigger a rebuild.

If you edit `conf/versions.json`, the builder automatically refreshes missing
base-image records before generating or building images. You can also refresh
all currently configured tags without changing Joomla versions:

```bash
./src/bin/check-joomla-releases.sh --refresh-current
```

Commit `conf/versions.json` and `conf/upstream-images.json` together after a manual
refresh. Changes to either file trigger the publisher on `master`.

### Build triggers

* A JCB release dispatch
* An MCP release dispatch (`pkg-joomengine-mcp-updated`), or detection by the six-hour poll
* A build-input change merged to `master`
* A ready Joomla version or official base-image digest change
* Manual dispatch

### What CI does

1. Checks out the repository
2. Installs required tooling
3. Runs deterministic unit tests
4. Registers cross-architecture emulation and creates a Buildx builder
5. Authenticates with Docker
6. Runs `./src/bin/joomengine.sh`
7. Commits the generated image contexts, build-state files, and any refreshed upstream digests

Pull requests also run ShellCheck, actionlint, JSON validation, and deterministic
tests for release selection, compatibility, build state, tags, and startup. Image
smoke gates render fresh Dockerfiles from the submitted template and build standard
and MCP images for native AMD64 Apache, FPM, and FPM-Alpine, plus emulated ARM64
Apache. Native Apache tests deploy Joomla against MariaDB, verify installed
extensions, and restart the container to check one-time installation behavior.

### What CI does *not* do

* It does **not** contain build logic
* It does **not** define tagging rules
* It does **not** hide behavior in YAML

All logic remains reviewable and reproducible locally.

---

## 🧪 Running Locally

You can run the build engine locally:

```bash
./src/bin/joomengine.sh
```

Useful flags:

```bash
-q, --quiet        Suppress all stdout output (exit code only)
-n, --dry-run      Generate/review contexts without building or changing hashes
-f, --force        Force update docker folder/files
    --build-only   Build and load one platform locally, do not push
    --platforms    Use auto or an explicit comma-separated platform list
-h, --help         Show this help and exit
```

Normal publication defaults to `--platforms auto`, which uses the complete
platform set verified for each official Joomla base image. `--build-only`
loads one platform into the local Docker image store, defaulting to the host
platform. Use an explicit single-platform override when needed, for example:

```bash
./src/bin/joomengine.sh --build-only --platforms linux/arm64/v8
```

For publication or focused diagnostics, `--platforms` can also override the
automatic selection with an explicit comma-separated list.

---

## 🧾 License

```txt
Copyright (C) 2021-2026
Llewellyn van der Merwe

Licensed under the **GNU General Public License v2 (GPLv2)**
See `LICENSE` for details.
```
