# Joomla Component Builder Docker images

JoomEngine builds and publishes Joomla Component Builder (JCB) images on top of
[official Joomla images](https://hub.docker.com/_/joomla). Joomla's own entrypoint
installs the verified JCB package, and the optional MCP package, during first
installation. JoomEngine does not supply or replace the runtime entrypoint.

Images are published at [octoleo/joomengine](https://hub.docker.com/r/octoleo/joomengine).
See [Docker usage](docker/README.md) for deployment, configuration, and debugging.

## Normal and development images

There are two independent image choices:

- The **profile** is `standard` or `dev`. Development images extend the matching
  official Joomla `-dev` image and inherit its development tools and settings.
- The **flavor** is `standard` (JCB only) or `mcp` (JCB and the MCP package).

`latest` and `latest-mcp` select the highest stable eligible JCB release, Apache,
and the highest configured PHP version, using the profile selected by
`defaultProfile` in `conf/build.json`. The configured default is `dev`.

Explicit default aliases let deployments choose the environment independently:

```bash
docker pull octoleo/joomengine:latest-dev
docker pull octoleo/joomengine:latest-dev-mcp
docker pull octoleo/joomengine:latest-standard
docker pull octoleo/joomengine:latest-standard-mcp
```

Existing versioned and rolling tags without `-dev` keep their normal-image
meaning. Development counterparts append `-dev`, followed by `-mcp` when needed:

```bash
docker pull octoleo/joomengine:6-php8.4-apache
docker pull octoleo/joomengine:6-php8.4-apache-dev
docker pull octoleo/joomengine:6-php8.4-apache-mcp
docker pull octoleo/joomengine:6-php8.4-apache-dev-mcp
```

The leading version identifies JCB, not Joomla. The exact Joomla release, PHP
version, base image digest, and bundled package versions are recorded in the
manifest and image labels. Each tag is a multi-platform Linux image using the
platforms actually published for its selected upstream base.

The configured Joomla 6 series has both profiles. Joomla 4 and 5 retain normal
profiles because matching official development images are not published for
those configured series. Adding a profile requires its complete upstream tag
matrix to be available; the builder never substitutes a different Joomla series.

Development images include Xdebug, Composer, Node/npm, Git, SSH tooling, and the
other tools provided by Joomla. To remove these tools from a container, recreate
it from the matching normal image while keeping its site volume and database.
`XDEBUG_MODE=off` disables debugging but leaves the tools installed.

## JSON configuration

The build engine is Bash with `jq` for JSON and `xmlstarlet` for upstream release
XML. It emits Dockerfiles directly; there is no downloaded template renderer.

The source configuration is:

- [`conf/build.json`](conf/build.json): image repository, upstream sources,
  profile suffixes, default profile, labels, package directory, and automatic
  deployment environment defaults.
- [`conf/versions.json`](conf/versions.json): supported Joomla series and their
  pinned releases, PHP versions, runtime variants, and profiles.
- [`conf/maintainers.json`](conf/maintainers.json): authors used to generate
  `org.opencontainers.image.authors`.

Resolved state is separate:

- `conf/upstream-images.json` records verified registry index and platform digests.
- `conf/manifest.ndjson` records every generated context, its profile, flavor,
  tags, release metadata, and base-image pin.
- `conf/hashes.txt` records successful builds and alias topology.

Change JSON configuration, then review generated output with:

```bash
./src/bin/joomengine.sh --dry-run --force
```

Changes to image configuration are included in build fingerprints. Editing
configuration or rendering logic triggers the publishing workflow on `master`.
Generated Dockerfiles belong under `images/`; edit the JSON or Bash source, then
regenerate rather than editing generated files.

## Package verification and startup

The builder reads the configured JCB update XML for each major and resolves the
latest stable MCP package once per build batch. The package metadata supplies
versioned download URLs and SHA-512 hashes. Missing metadata or a failed checksum
aborts the build.

The Dockerfile downloads the packages into `/usr/src/joomengine` by default and
sets `JOOMLA_EXTENSIONS_PATHS` to the local JCB ZIP, followed by the MCP ZIP for
MCP images. Downloads and checksum validation happen during the image build;
installation into the site's database happens during automatic deployment.

The MCP ZIP contains the component, console plugin, and webservices plugin. MCP
images are generated only when the selected Joomla/PHP combination satisfies the
package's update XML constraints. MCP changes rebuild MCP images independently;
they do not change which plain images contain JCB alone.

Image environment declarations preserve JoomEngine's automatic site/admin
configuration defaults. Deployment environment values can replace them, including
the complete extension-path list. Existing installed volumes are not upgraded or
reinstalled when a container restarts or changes images. See
[the environment contract](docker/README.md#environment-and-first-installation)
for the exact runtime behavior and differences in historical Joomla 4 images.

## Automatic upstream updates

Every six hours, the release poller reads the configured Joomla stable-release
feed and verifies every configured PHP, runtime, and profile combination directly
against the Docker registry. It checks the registry index's SHA-256 digest and
records every runnable Linux platform descriptor, ignoring attestations.

A new Joomla release advances only when the complete configured image matrix is
published. Missing dev tags keep that series waiting without a partial promotion.
Changes to an existing normal or dev base digest also trigger rebuilds, even when
the Joomla version is unchanged. Platform additions and removals are tracked too.

The poller atomically updates the version and digest JSON, checks for MCP updates,
and dispatches the normal publishing workflow. A manually edited matrix causes
the builder to resolve missing upstream pins before building. To refresh the
current matrix without advancing Joomla releases:

```bash
./src/bin/check-joomla-releases.sh --refresh-current
```

The publisher builds changed images, verifies their multi-platform publication,
and promotes rolling/default aliases only after all required builds succeed.
Successful build state is committed only after that publication completes.

## Tag policy

All release combinations have a full tag of the form
`<jcb-version>-php<php>-<runtime>`, with the profile suffix and then optional
`-mcp` suffix. Apache also receives a PHP shorthand. The highest configured PHP
receives runtime and Apache version shorthands. Stable leaders receive major and
minor rolling aliases for their profile/flavor.

Prerelease tags retain their alpha, beta, or RC channel and never claim stable
aliases. Default aliases are controlled separately from the explicit profile
tags, so changing `defaultProfile` does not repurpose existing versioned tags.
Pin the resulting image digest when a deployment must use identical image bytes.

## Validation

Pull requests run shell syntax checks, ShellCheck, actionlint, JSON validation,
and deterministic tests for configuration, rendering, release detection, package
compatibility, build state, and tags.

Image smoke jobs derive their matrix from the generated manifest. They cover the
configured profiles, flavors, and runtime variants of the latest stable images,
using published AMD64 platforms and ARM64 Apache samples. An additional normal
Apache context from the oldest active series covers historical upstream startup
(currently Joomla 4). Removing a series or profile from JSON also removes those
cases from CI.

The jobs check inherited startup metadata, verified archives, and expected
development tools. Apache deployment tests verify installed extensions, console
commands, and restart without reinstalling. When an exact normal counterpart
exists, they also switch a dev site to it while preserving the database and volume.

Run the deterministic suite locally with:

```bash
./tests/run.sh
```

## Local build options

```bash
./src/bin/joomengine.sh --dry-run
./src/bin/joomengine.sh --build-only
./src/bin/joomengine.sh --build-only --platforms linux/arm64/v8
```

Normal publication defaults to every platform verified for each base image.
`--build-only` loads one platform locally; `--platforms` selects an explicit
supported subset. `--force` regenerates contexts and `--quiet` suppresses stdout.
Run `./src/bin/joomengine.sh --help` for the complete options.

## License

Copyright (C) 2021–2026 Llewellyn van der Merwe.
Licensed under GNU General Public License v2. See [LICENSE](LICENSE).
