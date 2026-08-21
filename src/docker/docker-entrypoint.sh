#!/bin/bash
set -euo pipefail

# Load database password from file if specified
if [ -n "${JOOMLA_DB_PASSWORD_FILE:-}" ] && [ -f "${JOOMLA_DB_PASSWORD_FILE}" ]; then
    # If the password file ends with a newline (common with Docker secrets), the newline will be preserved.
    # MySQL typically tolerates this, but downstream consumers should be aware that the value is not trimmed.
    JOOMLA_DB_PASSWORD=$(cat "$JOOMLA_DB_PASSWORD_FILE")
fi

# Always auto deploy
#   so ensure we have defaults for these values
: "${JOOMLA_DB_USER:=joomengine}"
: "${JOOMLA_DB_NAME:=joomengine}"
: "${JOOMLA_SITE_NAME:=Joomla Component Builder - JoomEngine}"
: "${JOOMLA_ADMIN_USER:=JoomEngine Hero}"
: "${JOOMLA_ADMIN_USERNAME:=joomengine}"
: "${JOOMLA_ADMIN_PASSWORD:=joomengine@secure}"
: "${JOOMLA_ADMIN_EMAIL:=joomengine@example.com}"

: "${JOOMLA_WEBROOT:=/var/www/html}"
: "${JCB_ZIP_PATH:=/usr/src/joomengine/jcb.zip}"

# Function to log messages
joomla_log() {
    local msg="$1"
    echo >&2 " $msg"
}

# Function to log info messages
joomla_log_info() {
    local msg="$1"
    echo >&2 "[INFO] $msg"
}

# Function to log warning messages
joomla_log_warning() {
    local msg="$1"
    echo >&2 "[WARNING] $msg"
}

# Function to log error messages
joomla_log_error() {
    local msg="$1"
    echo >&2 "[ERROR] $msg"
}

# Function to set a line
joomla_echo_line() {
    echo >&2 "========================================================================"
}

# Function to set a line at end
joomla_echo_line_start() {
    joomla_echo_line
    echo >&2
}

# Function to set a line at end
joomla_echo_line_end() {
    echo >&2
    joomla_echo_line
}

# Function to give final success message (1)
joomla_log_configured_success_message() {
    joomla_log "This server is now configured to run Joomla!"
}

# Function to give final success message (2)
joomla_log_success_and_need_db_message() {
    joomla_log_configured_success_message
    echo >&2
    joomla_log " NOTE: You will need your database server address, database name,"
    joomla_log "       and database user credentials to install Joomla."
}

# Function to validate URLs
#
# The URL validation regex is intentionally strict.
#
# It excludes:
#   - IP-based URLs
#   - URLs with ports
#   - localhost
#   - Some query-based installer URLs
#
joomla_validate_url() {
    if [[ $1 =~ ^http(s)?://[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}(/.*)?$ ]]; then
        return 0
    else
        return 1
    fi
}

# Function to validate file path
joomla_validate_path() {
    if [[ -f $1 ]]; then
        return 0
    else
        return 1
    fi
}

# Function to split values by semicolon
joomla_get_array_by_semicolon() {
    local input=$1   # The input string to be split
    local -n arr=$2  # The array to store the split values (passed by reference)
    local old_IFS=$IFS  # Save the original IFS value
    # shellcheck disable=SC2034
    # passed by reference
    IFS=';' read -ra arr <<< "$input"  # Split the input by semicolon and store in array
    IFS=$old_IFS  # Restore the original IFS value
}

# Function to split values by colon to get host and port
#
# Host/port parsing assumes hostname:port format and does not support IPv6 addresses (e.g. [::1]:587).
# This is fine for IPv4-only environments but is a limitation.
joomla_get_host_port_by_colon() {
    local input=$1    # The input string to be split
    local -n hostname=$2  # The variable to store the hostname (passed by reference)
    local -n port=$3  # The variable to store the port (passed by reference)
    local old_IFS=$IFS  # Save the original IFS value
    # shellcheck disable=SC2034
    # passed by reference
    IFS=':' read -r hostname port <<< "$input"  # Split the input by colon and store in hostname and port
    IFS=$old_IFS  # Restore the original IFS value
}

# Run a Joomla CLI command
#
# CLI commands passed via JOOMLA_CLI_COMMANDS are split on whitespace into
# argv. Shell evaluation, substitutions, pipes, and redirects are not used.
joomla_run_cli() {
    if [[ "$#" -eq 0 ]]; then
        joomla_log_error "No Joomla CLI command provided"
        return 1
    fi

    # Execute Joomla CLI with passed arguments
    if php "${JOOMLA_WEBROOT}/cli/joomla.php" "$@"; then
        joomla_log_info "Joomla CLI command succeeded: $*"
        return 0
    else
        joomla_log_error "Joomla CLI command failed: $*"
        return 1
    fi
}

# Run a Joomla CLI command provided as a single string
# Used for env / compose / config-based commands
joomla_run_cli_string() {
    local command_string="$1"

    if [[ -z "$command_string" ]]; then
        joomla_log_error "Empty Joomla CLI command string"
        return 1
    fi

    # Controlled word-splitting into argv
    local -a CLI_ARGS=()
    read -r -a CLI_ARGS <<< "$command_string"

    joomla_run_cli "${CLI_ARGS[@]}"
}

# Function to install extension from URL
joomla_install_extension_via_url() {
    local url=$1
    if joomla_validate_url "$url"; then
        joomla_run_cli extension:install --url "$url" --no-interaction
    else
        joomla_log_error "Invalid URL: $url"
        return 1
    fi
}

# Function to install extension from path
joomla_install_extension_via_path() {
    local path=$1
    if joomla_validate_path "$path"; then
        joomla_run_cli extension:install --path "$path" --no-interaction
    else
        joomla_log_error "Invalid Path: $path"
        return 1
    fi
}

# Function to validate necessary environment variables
joomla_validate_vars() {
    # Basic email regex for validation
    local email_regex="^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$"

    # Check if JOOMLA_SITE_NAME is longer than 2 characters
    if [[ "${#JOOMLA_SITE_NAME}" -le 2 ]]; then
        joomla_log_error "JOOMLA_SITE_NAME must be longer than 2 characters!"
        return 1
    fi

    # Check if JOOMLA_ADMIN_USER is longer than 2 characters
    if [[ "${#JOOMLA_ADMIN_USER}" -le 2 ]]; then
        joomla_log_error "JOOMLA_ADMIN_USER must be longer than 2 characters!"
        return 1
    fi

    # Check if JOOMLA_ADMIN_USERNAME has no spaces, and is only alphabetical
    if [[ "${JOOMLA_ADMIN_USERNAME}" =~ [^a-zA-Z] ]]; then
        joomla_log_error "JOOMLA_ADMIN_USERNAME must contain no spaces and be only alphabetical!"
        return 1
    fi

    # Check if JOOMLA_ADMIN_PASSWORD is longer than 12 characters
    if [[ "${#JOOMLA_ADMIN_PASSWORD}" -le 12 ]]; then
        joomla_log_error "JOOMLA_ADMIN_PASSWORD must be longer than 12 characters!"
        return 1
    fi

    # Check if JOOMLA_ADMIN_EMAIL is a valid email
    if [[ ! "${JOOMLA_ADMIN_EMAIL}" =~ $email_regex ]]; then
        joomla_log_error "JOOMLA_ADMIN_EMAIL must be a valid email address!"
        return 1
    fi

    return 0
}

# Function to check if auto deploy can be done
joomla_can_auto_deploy() {
    if [[ -n "${JOOMLA_SITE_NAME}" && -n "${JOOMLA_ADMIN_USER}" &&
          -n "${JOOMLA_ADMIN_USERNAME}" && -n "${JOOMLA_ADMIN_PASSWORD}" &&
          -n "${JOOMLA_ADMIN_EMAIL}" ]]; then

        if joomla_validate_vars; then
            return 0
        fi
    fi

    return 1
}

# Resolve a user reference to a numeric UID.
#
# Apache accepts numeric identities prefixed with '#'. Docker users commonly
# provide either '#1000' or '1000', so both forms are supported here.
joomla_resolve_uid() {
    local identity="${1#\#}"

    if [[ "$identity" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$identity"
        return 0
    fi

    if id -u "$identity" >/dev/null 2>&1; then
        id -u "$identity"
        return 0
    fi

    joomla_log_error "Unable to resolve runtime user '$1'."
    return 1
}

# Resolve a group reference to a numeric GID without assuming that a user with
# the same name exists.
joomla_resolve_gid() {
    local identity="${1#\#}"
    local entry

    if [[ "$identity" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$identity"
        return 0
    fi

    if command -v getent >/dev/null 2>&1; then
        entry="$(getent group "$identity" 2>/dev/null || true)"
        if [[ -n "$entry" ]]; then
            printf '%s\n' "$entry" | awk -F: '{ print $3; exit }'
            return 0
        fi
    fi

    entry="$(awk -F: -v name="$identity" '$1 == name { print $3; exit }' /etc/group)"
    if [[ -n "$entry" ]]; then
        printf '%s\n' "$entry"
        return 0
    fi

    joomla_log_error "Unable to resolve runtime group '$1'."
    return 1
}

# Resolve the identity used by the Apache/FPM worker processes. Bootstrap and
# the server master process retain the official image's root startup model.
joomla_resolve_runtime_identity() {
    local server_command="$1"
    local raw_user
    local raw_group

    if ! uid="$(id -u)" || ! gid="$(id -g)"; then
        joomla_log_error "Unable to resolve the entrypoint UID:GID."
        return 1
    fi

    if [[ "$uid" != '0' ]]; then
        user="$uid"
        group="$gid"
        return 0
    fi

    case "$server_command" in
    apache2*)
        raw_user="${APACHE_RUN_USER:-www-data}"
        raw_group="${APACHE_RUN_GROUP:-www-data}"
        if ! user="$(joomla_resolve_uid "$raw_user")" || \
            ! group="$(joomla_resolve_gid "$raw_group")"; then
            return 1
        fi

        # Apache requires '#' for a numeric User/Group directive. Normalizing
        # bare numeric values keeps APACHE_RUN_* and the resolved IDs aligned.
        if [[ "${raw_user#\#}" =~ ^[0-9]+$ ]]; then
            APACHE_RUN_USER="#$user"
            export APACHE_RUN_USER
        fi
        if [[ "${raw_group#\#}" =~ ^[0-9]+$ ]]; then
            APACHE_RUN_GROUP="#$group"
            export APACHE_RUN_GROUP
        fi
        ;;
    *) # php-fpm
        if ! user="$(joomla_resolve_uid 'www-data')" || \
            ! group="$(joomla_resolve_gid 'www-data')"; then
            return 1
        fi
        ;;
    esac

    if [[ "$user" == '0' || "$group" == '0' ]]; then
        joomla_log_error "Refusing to assign Joomla ownership to root (${user}:${group})."
        return 1
    fi

    joomla_log_info "Joomla runtime identity resolved to UID:GID ${user}:${group}."
}

# Deterministic finalizer: all synchronous installation/CLI activity has
# finished before this runs. Always repair the complete tree when root, then
# restore Joomla's read-only configuration.php mode.
joomla_repair_webroot_ownership() {
    if [[ "$uid" != '0' ]]; then
        return 0
    fi

    joomla_log_info \
        "Repairing ${JOOMLA_WEBROOT} ownership for runtime UID:GID ${user}:${group}."

    if ! chown -R "$user:$group" "$JOOMLA_WEBROOT"; then
        joomla_log_error \
            "Failed to repair ${JOOMLA_WEBROOT} ownership for UID:GID ${user}:${group}."
        return 1
    fi

    if [[ -e "${JOOMLA_WEBROOT}/configuration.php" ]] && \
        ! chmod 0444 "${JOOMLA_WEBROOT}/configuration.php"; then
        joomla_log_error "Failed to restore configuration.php permissions to 0444."
        return 1
    fi

    joomla_log_info \
        "Ownership repair completed successfully for UID:GID ${user}:${group}."
}

# Run the ownership repair once. A state value avoids retrying a failed chown
# from the EXIT trap and prevents a second traversal after successful startup.
joomla_finalize_webroot() {
    case "${JOOMLA_OWNERSHIP_FINALIZER_STATE:-pending}" in
    complete)
        return 0
        ;;
    running | failed)
        return 1
        ;;
    esac

    JOOMLA_OWNERSHIP_FINALIZER_STATE='running'
    if joomla_repair_webroot_ownership; then
        JOOMLA_OWNERSHIP_FINALIZER_STATE='complete'
        return 0
    fi

    JOOMLA_OWNERSHIP_FINALIZER_STATE='failed'
    return 1
}

# Repair ownership even when a synchronous installer/extension/CLI command
# aborts startup. Preserve the original error unless the repair itself fails.
joomla_finalize_webroot_on_exit() {
    local exit_status="$?"

    trap - EXIT
    if ! joomla_finalize_webroot; then
        exit_status=1
    fi

    exit "$exit_status"
}

joomla_main() {
    if [[ "$#" -eq 0 ]]; then
        joomla_log_error "No startup command was provided."
        return 1
    fi

    if [[ "$1" != apache2* && "$1" != "php-fpm" ]]; then
        exec "$@"
    fi

    joomla_resolve_runtime_identity "$1"
    cd "$JOOMLA_WEBROOT"
    JOOMLA_OWNERSHIP_FINALIZER_STATE='pending'
    trap joomla_finalize_webroot_on_exit EXIT

# start Joomla message block
joomla_echo_line_start
if [ -n "${MYSQL_PORT_3306_TCP:-}" ]; then
    if [ -z "${JOOMLA_DB_HOST:-}" ]; then
        JOOMLA_DB_HOST='mysql'
    else
        joomla_log_warning "both JOOMLA_DB_HOST and MYSQL_PORT_3306_TCP found"
        joomla_log "Connecting to JOOMLA_DB_HOST ($JOOMLA_DB_HOST)"
        joomla_log "instead of the linked mysql container"
    fi
fi

if [ -z "${JOOMLA_DB_HOST:-}" ]; then
    joomla_log_error "Missing JOOMLA_DB_HOST and MYSQL_PORT_3306_TCP environment variables."
    joomla_log "Did you forget to --link some_mysql_container:mysql or set an external db"
    joomla_log "with -e JOOMLA_DB_HOST=hostname:port?"
    # end Joomla message block
    joomla_echo_line_end
    exit 1
fi

# If the DB user is 'root' then use the MySQL root password env var
if [ "$JOOMLA_DB_USER" = 'root' ]; then
    : "${JOOMLA_DB_PASSWORD:=$MYSQL_ENV_MYSQL_ROOT_PASSWORD}"
fi

if [ -z "${JOOMLA_DB_PASSWORD:-}" ] && [ "${JOOMLA_DB_PASSWORD_ALLOW_EMPTY:-}" != 'yes' ]; then
    joomla_log_error "Missing required JOOMLA_DB_PASSWORD environment variable."
    joomla_log "Did you forget to -e JOOMLA_DB_PASSWORD=... ?"
    joomla_log "(Also of interest might be JOOMLA_DB_USER and JOOMLA_DB_NAME.)"
    # end Joomla message block
    joomla_echo_line_end
    exit 1
fi

if [ ! -e index.php ] && [ ! -e libraries/src/Version.php ]; then
    # if the directory exists and Joomla doesn't appear to be installed AND the permissions of it are root:root, let's chown it (likely a Docker-created directory)
    if [ "$uid" = '0' ] && [ "$(stat -c '%u:%g' .)" = '0:0' ]; then
        chown "$user:$group" .
    fi

    joomla_log_info "Joomla not found in $PWD - copying now..."
    if [ "$(ls -A)" ]; then
        joomla_log_warning "$PWD is not empty - press Ctrl+C now if this is an error!"
        (
            set -x
            ls -A
            sleep 10
        )
    fi
    # use full commands
    # for clearer intent
    sourceTarArgs=(
        --create
        --file -
        --directory /usr/src/joomla
        --one-file-system
        --owner "$user" --group "$group"
    )
    targetTarArgs=(
        --extract
        --file -
    )
    if [ "$uid" != '0' ]; then
        # avoid "tar: .: Cannot utime: Operation not permitted" and "tar: .: Cannot change mode to rwxr-xr-x: Operation not permitted"
        targetTarArgs+=(--no-overwrite-dir)
    fi

    tar "${sourceTarArgs[@]}" . | tar "${targetTarArgs[@]}"

    if [ ! -e .htaccess ]; then
        # NOTE: The "Indexes" option is disabled in the php:apache base image so remove it as we enable .htaccess
        sed -r 's/^(Options -Indexes.*)$/#\1/' htaccess.txt > .htaccess
        chown "$user:$group" .htaccess
    fi

    joomla_log "Complete! Joomla has been successfully copied to $PWD"
fi

# Ensure the MySQL Database is created.
php /makedb.php "$JOOMLA_DB_HOST" "$JOOMLA_DB_USER" "$JOOMLA_DB_PASSWORD" \
    "$JOOMLA_DB_NAME" "${JOOMLA_DB_TYPE:-mysqli}"

# if the (installation) directory exists and we can auto deploy
if [ -d "${JOOMLA_WEBROOT}/installation" ] && [ -e "${JOOMLA_WEBROOT}/installation/joomla.php" ] && joomla_can_auto_deploy; then
    # use full commands
    # for clearer intent
    installJoomlaArgs=(
        --site-name="${JOOMLA_SITE_NAME}"
        --admin-email="${JOOMLA_ADMIN_EMAIL}"
        --admin-username="${JOOMLA_ADMIN_USERNAME}"
        --admin-user="${JOOMLA_ADMIN_USER}"
        --admin-password="${JOOMLA_ADMIN_PASSWORD}"
        --db-type="${JOOMLA_DB_TYPE:-mysqli}"
        --db-host="${JOOMLA_DB_HOST}"
        --db-name="${JOOMLA_DB_NAME}"
        --db-pass="${JOOMLA_DB_PASSWORD}"
        --db-user="${JOOMLA_DB_USER}"
        --db-prefix="${JOOMLA_DB_PREFIX:-joom_}"
        --db-encryption=0
    )

    # Run the auto deploy (install)
    if php "${JOOMLA_WEBROOT}/installation/joomla.php" install "${installJoomlaArgs[@]}"; then
        # The PHP command succeeded (so we remove the installation folder)
        rm -rf "${JOOMLA_WEBROOT}/installation"

        joomla_log_configured_success_message

        # Install any extensions found in the extensions urls env
        if [[ -n "${JOOMLA_EXTENSIONS_URLS:-}" && "${#JOOMLA_EXTENSIONS_URLS}" -gt 2 ]]; then
            joomla_get_array_by_semicolon "$JOOMLA_EXTENSIONS_URLS" J_E_URLS
            for extension_url in "${J_E_URLS[@]}"; do
                joomla_install_extension_via_url "$extension_url"
            done
        fi

        # Install any extensions found in the extensions paths env
        if [[ -n "${JOOMLA_EXTENSIONS_PATHS:-}" && "${#JOOMLA_EXTENSIONS_PATHS}" -gt 2 ]]; then
            joomla_get_array_by_semicolon "$JOOMLA_EXTENSIONS_PATHS" J_E_PATHS
            for extension_path in "${J_E_PATHS[@]}"; do
                joomla_install_extension_via_path "$extension_path"
            done
        fi

        # Install official JCB package (always-once)
        joomla_install_extension_via_path "$JCB_ZIP_PATH"

        if [[ -n "${JOOMLA_SMTP_HOST:-}" && "${JOOMLA_SMTP_HOST}" == *:* ]]; then
            joomla_get_host_port_by_colon "$JOOMLA_SMTP_HOST" JOOMLA_SMTP_HOST JOOMLA_SMTP_HOST_PORT
        fi

        # add the smtp host to configuration file
        if [[ -n "${JOOMLA_SMTP_HOST:-}" && "${#JOOMLA_SMTP_HOST}" -gt 2 ]]; then
            chmod u+w "${JOOMLA_WEBROOT}/configuration.php"
            sed -i \
                "s/public \$mailer = 'mail';/public \$mailer = 'smtp';/g" \
                "${JOOMLA_WEBROOT}/configuration.php"
            sed -i \
                "s/public \$smtphost = 'localhost';/public \$smtphost = '${JOOMLA_SMTP_HOST}';/g" \
                "${JOOMLA_WEBROOT}/configuration.php"
        fi

        # add the smtp port to configuration file
        if [[ -n "${JOOMLA_SMTP_HOST_PORT:-}" ]]; then
            sed -i \
                "s/public \$smtpport = 25;/public \$smtpport = ${JOOMLA_SMTP_HOST_PORT};/g" \
                "${JOOMLA_WEBROOT}/configuration.php"
        fi

        # run cli commands if found
        if [[ -n "${JOOMLA_CLI_COMMANDS:-}" && "${#JOOMLA_CLI_COMMANDS}" -gt 2 ]]; then
            joomla_get_array_by_semicolon "$JOOMLA_CLI_COMMANDS" J_C_COMMANDS
            for joomla_command in "${J_C_COMMANDS[@]}"; do
                joomla_run_cli_string "$joomla_command"
            done
        fi

    else
        joomla_log_success_and_need_db_message
    fi
else
    joomla_log_success_and_need_db_message
fi

# Run after every normal startup, including already-installed sites. All
# installer, extension, SMTP, and configured CLI mutations above are
# synchronous, so this is the final filesystem mutation before server startup.
joomla_finalize_webroot
trap - EXIT

# end Joomla message block
joomla_echo_line_end

exec "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    joomla_main "$@"
fi
