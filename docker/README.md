# Run Joomla Component Builder

JoomEngine extends the official Joomla image, bundles verified JCB packages, and
lets Joomla perform automatic installation. The default `latest` image uses the
normal official Joomla environment. Add `-mcp` for the MCP component and its
console/webservices plugins, then `-dev` when development tools are wanted.

## Start a local environment

From this directory:

```bash
docker compose up -d
```

Open <http://localhost:8080/administrator/>. The example's administrator is
`joomengine` with password `joomengine@secure`. These existing development defaults
can be overridden through the service environment for a deployment.

The example stores Joomla and MariaDB data in named volumes. Do not remove those
volumes when recreating or switching containers.

## Choose the environment

The four latest aliases select the environment explicitly:

- `latest`: JCB on the normal Joomla image.
- `latest-mcp`: JCB and MCP on the normal Joomla image.
- `latest-dev`: JCB with development tools.
- `latest-mcp-dev`: JCB and MCP with development tools.

Versioned tags retain their existing normal-image meaning. Their development
counterparts add `-dev` after the optional MCP suffix. For example,
`6.2.0-php8.5-apache` and `6.2.0-php8.5-apache-dev` have the same JCB version,
configured Joomla base version, PHP version, and runtime; only the profile differs.
The MCP development counterpart is `6.2.0-php8.5-apache-mcp-dev`. Every development
tag ends in `-dev`. The leading version in every tag is JCB's version.

Joomla 6 images are configured for PHP 8.3, 8.4, and 8.5. Latest aliases and
version shorthands select PHP 8.5; explicit PHP 8.3 and 8.4 tags remain available.

Use the example Compose file's image setting to select a matching normal image:

```bash
JOOMENGINE_IMAGE=octoleo/joomengine:6.2.0-php8.5-apache \
  docker compose up -d --no-deps --pull always --force-recreate joomla
```

Switch back to its development counterpart with:

```bash
JOOMENGINE_IMAGE=octoleo/joomengine:6.2.0-php8.5-apache-dev \
  docker compose up -d --no-deps --pull always --force-recreate joomla
```

Set `JOOMENGINE_IMAGE` in this directory's `.env` file to retain the selection for
subsequent Compose commands. Keep the database, volumes, environment, and network
unchanged when switching. A normal image removes the development tools from the
new container. It does not remove project files or dependencies saved in volumes.
Changing images does not upgrade Joomla or extensions already installed there.

All configured runtime variants have normal images. Development tags are currently
available for the configured Joomla 6 series; Joomla 4 and 5 remain normal-only.
FPM and FPM-Alpine require a separate web server; the supplied example uses Apache.

### Images built for a specific Joomla release

The maintainer's `conf/versions.json` defines named targets. Each target chooses
an exact Joomla release and its stable/alpha/beta/RC channel, the JCB major and
release selector, PHP versions, runtimes, and profiles. JCB selectors can follow
one release channel or list exact package versions. A target can therefore test
stable JCB with preview Joomla, or preview JCB with stable Joomla, as an explicitly
selected experimental combination.

Additional targets use qualified tags with both application versions:

```text
<jcb-version>-joomla<joomla-version>-php<php>-<runtime>[-mcp][-dev]
```

The final `-dev` always selects development tools. A Joomla alpha/beta/RC version
inside a tag selects preview Joomla; it does not itself add development tools.
Qualified targets never change `latest`, `latest-mcp`, or the ordinary JCB version
aliases. Choose an exact published tag from the build manifest before deployment.

Stable-following targets automatically advance within their Joomla major once
all selected official image variants are published. Pinned targets keep the exact
Joomla version and refresh only its base-image digests. Joomla previews are pinned
explicitly; disabled future targets do not produce images. See the
[build-target configuration](../README.md#build-targets) for complete examples.

## Environment and first installation

Set `JOOMLA_DB_HOST` and either `JOOMLA_DB_PASSWORD` or
`JOOMLA_DB_PASSWORD_FILE` for automatic deployment. The image supplies these
defaults from `conf/build.json`:

```text
JOOMLA_DB_USER=joomengine
JOOMLA_DB_NAME=joomengine
JOOMLA_SITE_NAME=Joomla Component Builder - JoomEngine
JOOMLA_ADMIN_USER=JoomEngine Hero
JOOMLA_ADMIN_USERNAME=joomengine
JOOMLA_ADMIN_PASSWORD=joomengine@secure
JOOMLA_ADMIN_EMAIL=joomengine@example.com
JOOMLA_WEBROOT=/var/www/html
```

Joomla supplies the remaining database defaults, including `mysqli` and the
`joom_` table prefix. Override site and administrator values in the deployment
environment. Because the image declares `JOOMLA_ADMIN_PASSWORD`, the modern
upstream entrypoint rejects also setting `JOOMLA_ADMIN_PASSWORD_FILE`; use a direct
password override for these default images. A separately built image can omit the
password declaration when using file-based administrator credentials.

On a fresh Joomla 5/6 deployment, the inherited entrypoint initializes the database
and site, installs configured URL packages, installs local packages in their list
order, applies SMTP settings, and executes configured Joomla console commands.
Ownership is finalized after initialization. Existing configured sites skip these
initialization steps on subsequent starts.

If installation fails, Joomla 5/6 retains `.joomla-initializing` in the site volume
and blocks server startup. Inspect the logs and repair or restore the site and
database before clearing that marker. There is no downstream automatic MCP retry.
Historical Joomla 4 images inherit that version's earlier startup behavior;
they support automatic extension installation but not the current
`JOOMLA_CLI_COMMANDS` hook or initialization-marker recovery contract.

## Bundled and additional extensions

The default JCB image declares:

```text
JOOMLA_EXTENSIONS_PATHS=/usr/src/joomengine/jcb.zip
```

An MCP image declares:

```text
JOOMLA_EXTENSIONS_PATHS=/usr/src/joomengine/jcb.zip;/usr/src/joomengine/mcp.zip
```

These archives are downloaded and SHA-512 verified when building the image.
First deployment installs JCB followed by MCP. Startup uses those local archives
and does not resolve new JCB or MCP releases.

Docker replaces an environment variable's entire value when it is overridden.
If you replace `JOOMLA_EXTENSIONS_PATHS`, include the bundled paths in your new
semicolon-separated list if you still want those packages installed. An empty
value disables installation through that list; it does not remove the archives
from the image or uninstall extensions from an existing site.

`JOOMLA_EXTENSIONS_URLS` provides a separate semicolon-separated list of HTTP(S)
packages. Joomla processes URL packages before local packages. Packages that need
JCB already installed should therefore follow JCB in the local path list or be
installed explicitly after deployment.

## Joomla console and SMTP

On current Joomla 5/6 bases, `JOOMLA_CLI_COMMANDS` runs semicolon-separated Joomla
console commands after package installation. Commands are split into
whitespace-separated arguments without shell evaluation, pipes, or redirects.
They run once during automatic installation, not on ordinary restarts.

For example:

```yaml
environment:
  JOOMLA_CLI_COMMANDS: "cache:clean;extension:list --type=component"
```

Run commands explicitly on an installed site with:

```bash
docker compose exec --user www-data joomla php cli/joomla.php list
docker compose exec --user www-data joomla php cli/joomla.php extension:list --type=component
```

Initial SMTP configuration uses `JOOMLA_SMTP_HOST` and
`JOOMLA_SMTP_HOST_PORT`. For an existing site, change its Joomla mail settings.
Support for additional upstream variables follows the selected Joomla base.

## Debugging and development tools

The dev profile inherits Xdebug, Composer, Node/npm/npx, Git, SSH tools, PCNTL,
sockets, and the rest of Joomla's development tooling. Project dependencies still
belong in the project's Composer/npm manifests and lock files.

Xdebug is enabled with `develop,debug`; debug sessions start on a trigger. Enable
your IDE's PHP debugger listener on port 9003 and map the container's
`/var/www/html` to the matching local project directory. Xdebug connects outward
to the IDE: do not publish container port 9003.

The Compose example includes Linux Docker Engine's
`host.docker.internal:host-gateway` mapping. For a remote Docker host, set
`JOOMLA_XDEBUG_CLIENT_HOST` to an IDE address reachable from the container.
`JOOMLA_XDEBUG_CLIENT_PORT` defaults to `9003`.

Trigger a CLI debug session with:

```bash
docker compose exec -e XDEBUG_TRIGGER=1 joomla php cli/joomla.php list
```

For web requests, use a browser Xdebug extension or `?XDEBUG_TRIGGER=1`.
Check the installed extension with:

```bash
docker compose exec joomla php --ri xdebug
```

Set `XDEBUG_MODE=off` in the service environment and recreate the container to
disable Xdebug. This leaves the development tools installed; switch to a normal
image to remove them from the container. See the upstream
[development guide](https://github.com/joomla-docker/docker-joomla/blob/master/docs/development.md)
for editor configuration and connection diagnostics.

Run development commands as the owner of the project files. Supply writable
Composer/npm cache directories for that user and provide Git/SSH credentials
through deployment mounts or an SSH agent.
