# Joomla Component Builder - Official Docker Images

[![JoomEngine - Automated Build & Version Tracking](https://github.com/octoleo/joomengine/actions/workflows/joomengine.yml/badge.svg?branch=master)](https://github.com/octoleo/joomengine/actions/workflows/joomengine.yml)

This repository contains the **official Docker image build system** for
**Joomla Component Builder (JCB)**.

It is the canonical source for generating, tagging, and publishing all
Joomla Component Builder Docker images across supported:

- Joomla versions
- PHP versions
- Runtime variants (Apache / FPM / FPM-ALPINE)
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

[Docker details ->](https://github.com/octoleo/joomengine/blob/master/docker/README.md)

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
   * Builds only changed base images
   * Promotes rolling and `latest` aliases only after all base builds succeed
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
│   ├── upstream-images.json         # Verified Linux/amd64 Joomla image digests
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
2. Checks every configured PHP × variant tag on the official Joomla Docker Hub repository
3. Waits successfully, without a repository change or failed workflow, while any candidate tag is unavailable
4. Atomically updates `conf/versions.json` and `conf/upstream-images.json` only when a complete matrix is ready
5. Dispatches the normal image publisher only when a version or tracked digest changed

Digest-only changes are deliberate rebuild triggers, so refreshed upstream base
images receive the same verification and publication path as new Joomla releases.

### Build triggers

* A JCB release dispatch
* A build-input change merged to `master`
* A ready Joomla version or official base-image digest change
* Manual dispatch

### What CI does

1. Checks out the repository
2. Installs required tooling
3. Runs deterministic unit tests
4. Authenticates with Docker
5. Runs `./src/bin/joomengine.sh`
6. Commits only the generated image contexts and build-state files

Pull requests also run ShellCheck, actionlint, JSON validation, unit tests, and
representative Apache, FPM, and FPM-Alpine image builds.

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
    --build-only   Build images locally, do not push
-h, --help         Show this help and exit
```

This makes local testing identical to CI behavior.

---

## 🧾 License

```txt
Copyright (C) 2021-2026
Llewellyn van der Merwe

Licensed under the **GNU General Public License v2 (GPLv2)**
See `LICENSE` for details.
```
