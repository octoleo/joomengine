# Joomla Component Builder – Official Docker Images

These are the **official Docker images for Joomla Component Builder (JCB)**.

Each image provides a **ready-to-use Joomla environment** with **Joomla Component Builder automatically installed** and optionally configurable via environment variables and CLI commands.

No manual installation. No guessing. Just run the container.

[https://hub.docker.com/r/octoleo/joomengine](https://hub.docker.com/r/octoleo/joomengine)

---

## 🚀 What You Get

- ✅ Joomla (official base image)
- ✅ Joomla Component Builder (JCB) preloaded in the image
- ✅ Automatic Joomla + JCB installation on first run
- ✅ Safe one-time install (idempotent)
- ✅ Deterministic, fail-fast container startup (`set -euo pipefail`)
- ✅ Optional extension installation via URL or path
- ✅ Optional Joomla CLI automation
- ✅ SMTP configuration support
- ✅ Web workers run as the configured Apache identity or FPM `www-data`
- ✅ Unconditional ownership repair after all startup mutations

These images are ideal for:

- Local JCB development
- CI/CD pipelines
- Automated component compilation
- Reproducible Joomla build environments

---

## 📦 Available Images

All images are published under:
```
octoleo/joomengine
```

Examples:
```bash
docker pull octoleo/joomengine:latest
docker pull octoleo/joomengine:6.1.3
docker pull octoleo/joomengine:6.1.3-php8.2-apache
```

> `latest` always points to the **highest stable JCB release**, Apache variant, using the highest supported PHP version.

---

## 🧩 How It Works (Runtime Behavior)

When the container starts:

1. The **custom Joomla entrypoint** runs with strict error handling
2. If Joomla is not installed and all required variables are present:
   * Joomla is **automatically installed**
   * Database is created/verified
   * Admin account is configured
3. Once Joomla is configured (`configuration.php` exists):
   * Optional extensions are installed from URLs or paths
   * **Joomla Component Builder is installed automatically**
   * SMTP configuration is applied (if provided)
   * Optional Joomla CLI commands are executed
4. The complete Joomla tree is recursively repaired to the web-worker UID:GID
5. The upstream Apache/FPM server starts; its request workers run unprivileged

This guarantees:

* ✓ Fails fast on misconfiguration
* ✓ No silent fallbacks
* ✓ No race conditions
* ✓ No repeated installs
* ✓ No root-owned Joomla files after a successful startup finalizer
* ✓ Safe for repeated container restarts

---

## ⚙️ Environment Contract

This image is configured entirely via environment variables. All variables are optional unless stated otherwise.

The entrypoint runs in **strict mode** (`set -euo pipefail`). Missing or invalid critical values will cause the container to exit early and loudly.

### Required (Directly or Indirectly)

**Database Connection** - at least one of:
- `JOOMLA_DB_HOST` - Database hostname (optionally `host:port`)
- `MYSQL_PORT_3306_TCP` - Legacy Docker link support

**Database Password** - at least one of:
- `JOOMLA_DB_PASSWORD` - Direct password
- `JOOMLA_DB_PASSWORD_FILE` - Path to password file (e.g., Docker secrets)
- `MYSQL_ENV_MYSQL_ROOT_PASSWORD` - Used when `JOOMLA_DB_USER=root`
- `JOOMLA_DB_PASSWORD_ALLOW_EMPTY=yes` - Explicitly allow empty password

### Core Configuration Defaults

| Variable | Default |
|----------|---------|
| `JOOMLA_DB_USER` | `joomengine` |
| `JOOMLA_DB_NAME` | `joomengine` |
| `JOOMLA_DB_TYPE` | `mysqli` |
| `JOOMLA_DB_PREFIX` | `joom_` |
| `JOOMLA_SITE_NAME` | `Joomla Component Builder - JoomEngine` |
| `JOOMLA_ADMIN_USER` | `JoomEngine Hero` |
| `JOOMLA_ADMIN_USERNAME` | `joomengine` |
| `JOOMLA_ADMIN_PASSWORD` | `joomengine@secure` |
| `JOOMLA_ADMIN_EMAIL` | `joomengine@example.com` |

> The bundled administrator values are development defaults. Always override
> `JOOMLA_ADMIN_USERNAME`, `JOOMLA_ADMIN_PASSWORD`, and
> `JOOMLA_ADMIN_EMAIL` with deployment-specific secrets in production.

### Auto-Deploy Requirements

Automatic Joomla installation is performed **only if all** of the following are true:

- Joomla is not yet installed
- The `installation/` directory exists
- All admin variables are present and valid
- Validation passes:
  - `JOOMLA_SITE_NAME` > 2 characters
  - `JOOMLA_ADMIN_USER` > 2 characters
  - `JOOMLA_ADMIN_USERNAME` alphabetical only
  - `JOOMLA_ADMIN_PASSWORD` > 12 characters
  - `JOOMLA_ADMIN_EMAIL` valid email format

If any condition fails, the container starts normally without auto-install.

### Optional Extension Installation

Multiple values must be **semicolon-separated** (`;`):

- `JOOMLA_EXTENSIONS_URLS` - URLs to install after Joomla setup
- `JOOMLA_EXTENSIONS_PATHS` - Local paths to install after Joomla setup

⚠️ **URL validation is intentionally strict** (HTTPS/HTTP only, no IPs, no ports in domain).

### Joomla CLI Automation

- `JOOMLA_CLI_COMMANDS` - Semicolon-separated Joomla CLI commands

Each command is split on whitespace into arguments and passed directly to
`cli/joomla.php`. No shell evaluation, substitutions, pipes, or redirects are
performed.

#### Example
```yaml
environment:
  JOOMLA_CLI_COMMANDS: "cache:clean;extension:list --type=component"
```

What happens:

* Commands run synchronously during the entrypoint bootstrap
* Executed only after Joomla and JCB are ready
* Failures stop the container (safe by default)
* The final recursive ownership repair runs after the last command, including
  when a command fails

### SMTP Configuration (Optional)

- `JOOMLA_SMTP_HOST` - Format: `hostname` or `hostname:port`

⚠️ **IPv4 only** - IPv6 addresses (e.g., `[::1]:587`) are not supported.

### Execution Guarantees

✓ Fails fast on misconfiguration
✓ No silent fallbacks
✓ Deterministic startup behavior
✓ Safe for repeated container restarts
✓ Compatible with Apache and PHP-FPM variants

---

## 🐳 Example `docker-compose.yml`

### Minimal Setup
```yaml
services:
  joomla:
    image: octoleo/joomengine:latest
    ports:
      - "8080:80"
    environment:
      JOOMLA_DB_HOST: mariadb:3306
      JOOMLA_DB_USER: joomengine
      JOOMLA_DB_NAME: joomengine
      JOOMLA_DB_PASSWORD: secure_password12345
    depends_on:
      - mariadb
    volumes:
      - joomla_data:/var/www/html

  mariadb:
    image: mariadb:latest
    environment:
      MARIADB_USER: joomengine
      MARIADB_DATABASE: joomengine
      MARIADB_PASSWORD: secure_password12345
      MARIADB_ROOT_PASSWORD: your_root_secure_password12345
    volumes:
      - mariadb_data:/var/lib/mysql

volumes:
  joomla_data:
  mariadb_data:
```

### With JCB CLI Automation
```yaml
services:
  joomla:
    image: octoleo/joomengine:latest
    ports:
      - "8080:80"
    environment:
      JOOMLA_DB_HOST: mariadb:3306
      JOOMLA_DB_USER: joomengine
      JOOMLA_DB_NAME: joomengine
      JOOMLA_DB_PASSWORD: secure_password12345
      JOOMLA_CLI_COMMANDS: "componentbuilder:pull:joomla_component --items=d7e30702-ec49-45ac-8897-0389d61d6da0"
    depends_on:
      - mariadb
    volumes:
      - joomla_data:/var/www/html

  mariadb:
    image: mariadb:latest
    environment:
      MARIADB_USER: joomengine
      MARIADB_DATABASE: joomengine
      MARIADB_PASSWORD: secure_password12345
      MARIADB_ROOT_PASSWORD: your_root_secure_password12345
    volumes:
      - mariadb_data:/var/lib/mysql

volumes:
  joomla_data:
  mariadb_data:
```

Open your browser at:
```
http://localhost:8080
```

**Admin credentials:**
- Username: `joomengine`
- Password: `joomengine@secure`

These example credentials are for local development only. Override them for
every shared, staging, or production deployment.

---

## 🔐 Security & Permissions

* The entrypoint and upstream server master may start as root, matching the
  official Joomla Apache/FPM image model
* Apache request workers use `APACHE_RUN_USER` and `APACHE_RUN_GROUP`; numeric
  values such as `1000` are normalized to Apache's `#1000` form
* FPM request workers run as `www-data`
* Installer, extension, SMTP, and Joomla CLI operations are synchronous
* File ownership is always repaired recursively after those operations and on
  ordinary restarts; repair failures are fatal and visible
* Safe for persistent volumes
* Strict mode prevents silent misconfigurations

---

## 🧾 License

Copyright (C) 2021–2026
Llewellyn van der Merwe

Licensed under the **GNU General Public License v2 (GPLv2)**

See `LICENSE` for details.
