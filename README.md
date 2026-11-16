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

`latest` and `latest-mcp` select normal images for the highest stable eligible JCB
release, Apache, and the highest configured PHP version. Development tools are
opt-in through tags ending in `-dev`.

Explicit default aliases let deployments choose the environment independently:

```bash
docker pull octoleo/joomengine:latest
docker pull octoleo/joomengine:latest-mcp
docker pull octoleo/joomengine:latest-dev
docker pull octoleo/joomengine:latest-mcp-dev
```

Existing versioned and rolling tags without `-dev` keep their normal-image
meaning. Add `-mcp` for the MCP package, then `-dev` for development tools. Every
development tag ends in `-dev`:

```bash
docker pull octoleo/joomengine:6-php8.5-apache
docker pull octoleo/joomengine:6-php8.5-apache-mcp
docker pull octoleo/joomengine:6-php8.5-apache-dev
docker pull octoleo/joomengine:6-php8.5-apache-mcp-dev
```

The leading version identifies JCB, not Joomla. The exact Joomla release, PHP
version, base image digest, and bundled package versions are recorded in the
manifest and image labels. Each tag is a multi-platform Linux image using the
platforms actually published for its selected upstream base.

The configured Joomla 6 series has both profiles for PHP 8.3, 8.4, and 8.5. PHP 8.5
is the highest configured version and supplies the unqualified latest and version
shorthands; explicit PHP 8.3 and 8.4 tags remain available. Joomla 4 and 5 retain normal
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
  profile suffixes, labels, package directory, and automatic
  deployment environment defaults.
- [`conf/versions.json`](conf/versions.json): named build targets selecting Joomla
  releases, JCB releases, update/tag policies, PHP versions, runtimes, and profiles.
- [`conf/maintainers.json`](conf/maintainers.json): authors used to generate
  `org.opencontainers.image.authors`.

### Build targets

Each key in `conf/versions.json` is a target ID. IDs such as `4`, `5`, and `6`
keep the existing default targets recognizable; additional targets can use names
such as `joomla7-alpha`. The target selects Joomla and JCB independently.

For example, the current Joomla 6 target has this shape:

```json
{
  "6": {
    "enabled": true,
    "joomla": "6.2.0",
    "channel": "stable",
    "update": "stable",
    "tags": "default",
    "jcb": { "major": "6", "versions": "all" },
    "php": ["8.3", "8.4", "8.5"],
    "variants": ["apache", "fpm", "fpm-alpine"],
    "profiles": ["standard", "dev"]
  }
}
```

The fields have separate responsibilities:

- `enabled` controls whether the target participates in resolution and builds.
- `joomla` is an exact Joomla release. `channel` identifies it as `stable`,
  `alpha`, `beta`, or `rc` and must match the version.
- `update: "stable"` follows newer stable Joomla releases in the same major.
  `update: "pinned"` retains the chosen Joomla version while still refreshing
  its published base-image digests. Preview Joomla targets use `pinned`.
- `jcb.major` selects an update source from `conf/build.json`.
  `jcb.versions` can be `all`, `latest-stable`, `latest-alpha`, `latest-beta`,
  `latest-rc`, or an explicit array such as `["6.2.0", "6.2.1-alpha2"]`.
  This choice is independent of the Joomla release channel.
- `php`, `variants`, and `profiles` declare the combinations to build.
- `tags: "default"` assigns the existing JCB tag namespace. There can be only
  one default target per JCB major, and its Joomla channel must be stable.
  Additional targets use `tags: "qualified"`, which includes the Joomla
  version in each tag and never assigns global `latest` aliases.

Pinning Joomla does not pin JCB when its selector follows a release channel.
Use an explicit JCB version array when both application versions must stay fixed.
The engine rejects overlapping image combinations across targets rather than
letting one target overwrite another context or tag.

Preview targets can be recorded before enabling them. This disabled example uses
a hypothetical future Joomla alpha version to test the latest stable JCB:

```json
{
  "joomla7-alpha": {
    "enabled": false,
    "joomla": "7.0.0-alpha1",
    "channel": "alpha",
    "update": "pinned",
    "tags": "qualified",
    "jcb": { "major": "6", "versions": "latest-stable" },
    "php": ["8.5"],
    "variants": ["apache"],
    "profiles": ["standard", "dev"]
  }
}
```

The other direction selects a JCB release candidate on an existing stable Joomla
release. This target is also disabled until deliberately enabled for testing:

```json
{
  "jcb6-rc-on-stable": {
    "enabled": false,
    "joomla": "6.2.0",
    "channel": "stable",
    "update": "pinned",
    "tags": "qualified",
    "jcb": { "major": "6", "versions": "latest-rc" },
    "php": ["8.5"],
    "variants": ["apache"],
    "profiles": ["standard", "dev"]
  }
}
```

These snippets illustrate target entries; retain the other entries needed by
your configuration. The default `all` selector already includes available JCB
previews on stable Joomla. Before adding a separate target for the same combination,
adjust the default target's selection to prevent overlap. Enable experimental
pairs deliberately so their images and CI can test compatibility. Every configured
upstream image tag and the selected JCB release must exist before an enabled target
can build. The stable release feed does not discover or advance alpha, beta, or RC
Joomla versions; change those exact pinned versions in JSON deliberately.

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
regenerate rather than editing generated files. Generation also removes obsolete
generated Dockerfiles whose contexts are no longer selected, including during
`--dry-run`; unrelated files and manually maintained Dockerfiles are preserved.

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

A stable-following target advances only when its complete configured image matrix
is published. Missing dev tags keep that target waiting without a partial promotion.
Changes to an existing normal or dev base digest also trigger rebuilds, even when
the Joomla version is unchanged, including pinned preview targets. Platform
additions and removals are tracked too. Disabled targets are not fetched or built.

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

`conf/build.json` controls the final build and alias-publication order with
`publishLast`, listed from first to last:

```json
"publishLast": ["latest-mcp-dev", "latest-dev", "latest-mcp", "latest"]
```

Whenever a publishing run has any image or alias update, it rebuilds the images
owning these aliases after all other changed images, even if their own inputs
are unchanged. It then publishes all other aliases before this final sequence,
leaving normal JCB `latest` as the last build and the last tag published.
BuildKit may reuse unchanged layers. A completely unchanged run does nothing.
Aliases absent from the selected matrix are skipped; shared image owners build
once at their last configured position. An empty array disables this policy.
`--dry-run` shows this plan; `--build-only` orders its changed images the same
way but does not force unchanged defaults or publish to the registry.

This controls registry publication order. Docker Hub controls its display order;
Docker itself always uses `latest` when no tag is supplied, regardless of which
image was pushed most recently.

## Tag policy

All release combinations have a full tag of the form
`<jcb-version>-php<php>-<runtime>`, followed by optional `-mcp` and finally `-dev`
for development images. Apache also receives a PHP shorthand. The highest configured PHP
receives runtime and Apache version shorthands. Stable leaders receive major and
minor rolling aliases for their profile/flavor.

Qualified targets start with `<jcb-version>-joomla<joomla-version>`, followed by
PHP, runtime, optional `-mcp`, and optional `-dev`. For example, the full format
for JCB 6.2.0 on Joomla 6.2.0 is
`6.2.0-joomla6.2.0-php8.5-apache-mcp-dev` when a matching qualified target is
configured. Qualified targets do not claim the ordinary JCB rolling or latest
aliases.

JCB prerelease tags retain their alpha, beta, or RC channel and never claim stable
aliases. Joomla preview targets always use the qualified namespace, whether they
select stable or preview JCB packages. A preview JCB package can also be selected
on stable Joomla. Bare `latest` and `latest-mcp` remain normal images from stable
default targets; their development counterparts are `latest-dev` and
`latest-mcp-dev`.
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
cases from CI. A normal Apache sample on the highest earlier configured PHP
version retains coverage of the previous PHP baseline when one is available.
Qualified and preview-only targets receive their own representative smoke cases
per target, flavor, and JCB release channel. They never replace stable default
anchors, and profile switches require a matching target and platform.

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
