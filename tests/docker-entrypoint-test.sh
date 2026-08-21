#!/usr/bin/env bash
set -u

TEST_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/${BASH_SOURCE[0]##*/}"
ENTRYPOINT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/src/docker/docker-entrypoint.sh"

# The integration tests link command names to this file. This keeps all mock
# behavior in one auditable fixture and avoids changing the host system.
if [[ "${JOOMENGINE_ENTRYPOINT_MOCK:-0}" == '1' ]]; then
    mock_command="${0##*/}"
    case "$mock_command" in
    id)
        case "${1:-}" in
        -u)
            [[ "$#" -eq 1 ]] && printf '0\n' || printf '1201\n'
            ;;
        -g)
            [[ "$#" -eq 1 ]] && printf '0\n' || printf '1302\n'
            ;;
        *)
            exit 1
            ;;
        esac
        ;;
    php)
        printf 'php:%s\n' "$*" >> "$JOOMENGINE_TRACE_FILE"
        if [[ "${1:-}" == */installation/joomla.php ]]; then
            : > "${JOOMLA_WEBROOT}/configuration.php"
        fi
        if [[ -n "${JOOMENGINE_FAIL_PHP_MATCH:-}" && \
            "$*" == *"$JOOMENGINE_FAIL_PHP_MATCH"* ]]; then
            exit 37
        fi
        ;;
    tar)
        printf 'tar:%s\n' "$*" >> "$JOOMENGINE_TRACE_FILE"
        if [[ " $* " == *' --extract '* ]]; then
            cat >/dev/null
            mkdir -p "${JOOMLA_WEBROOT}/installation" "${JOOMLA_WEBROOT}/cli"
            : > "${JOOMLA_WEBROOT}/index.php"
            : > "${JOOMLA_WEBROOT}/installation/joomla.php"
            : > "${JOOMLA_WEBROOT}/cli/joomla.php"
            printf 'Options -Indexes\n' > "${JOOMLA_WEBROOT}/htaccess.txt"
        else
            printf 'mock Joomla archive\n'
        fi
        ;;
    chown | chmod)
        printf '%s:%s\n' "$mock_command" "$*" >> "$JOOMENGINE_TRACE_FILE"
        ;;
    apache2-foreground)
        printf '%s:%s:%s:%s\n' \
            "$mock_command" "$*" "${APACHE_RUN_USER:-}" "${APACHE_RUN_GROUP:-}" \
            >> "$JOOMENGINE_TRACE_FILE"
        ;;
    *)
        printf 'Unexpected mock command: %s\n' "$mock_command" >&2
        exit 1
        ;;
    esac
    exit 0
fi

failures=0
tests_run=0

fail() {
    printf 'not ok - %s\n' "$1" >&2
    return 1
}

assert_equal() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    if [[ "$actual" != "$expected" ]]; then
        fail "${message}: expected <${expected}>, got <${actual}>"
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"

    if [[ "$haystack" != *"$needle"* ]]; then
        fail "${message}: missing <${needle}>"
    fi
}

run_test() {
    local name="$1"
    local test_function="$2"

    tests_run=$((tests_run + 1))
    if (set -euo pipefail; "$test_function"); then
        printf 'ok %d - %s\n' "$tests_run" "$name"
    else
        failures=$((failures + 1))
        printf 'not ok %d - %s\n' "$tests_run" "$name" >&2
    fi
}

test_numeric_apache_identity() {
    # shellcheck source=../src/docker/docker-entrypoint.sh
    source "$ENTRYPOINT"

    id() {
        case "${1:-}" in
        -u) printf '0\n' ;;
        -g) printf '0\n' ;;
        *) return 1 ;;
        esac
    }

    APACHE_RUN_USER='1201'
    APACHE_RUN_GROUP='1302'
    joomla_resolve_runtime_identity apache2-foreground

    assert_equal '1201' "$user" 'numeric Apache UID'
    assert_equal '1302' "$group" 'numeric Apache GID'
    assert_equal '#1201' "$APACHE_RUN_USER" 'bare numeric Apache user normalization'
    assert_equal '#1302' "$APACHE_RUN_GROUP" 'bare numeric Apache group normalization'

    APACHE_RUN_USER='#1201'
    APACHE_RUN_GROUP='#1302'
    joomla_resolve_runtime_identity apache2-foreground
    assert_equal '#1201' "$APACHE_RUN_USER" 'prefixed numeric Apache user preservation'
    assert_equal '#1302' "$APACHE_RUN_GROUP" 'prefixed numeric Apache group preservation'
}

test_named_apache_identity() {
    # shellcheck source=../src/docker/docker-entrypoint.sh
    source "$ENTRYPOINT"

    id() {
        if [[ "${1:-}" == '-u' && "$#" -eq 1 ]]; then
            printf '0\n'
        elif [[ "${1:-}" == '-g' && "$#" -eq 1 ]]; then
            printf '0\n'
        elif [[ "${1:-}" == '-u' && "${2:-}" == 'web-user' ]]; then
            printf '1201\n'
        else
            return 1
        fi
    }
    getent() {
        case "$1:$2" in
        group:web-group) printf 'web-group:x:1302:\n' ;;
        passwd:1201) printf 'web-user:x:1201:1302::/srv/joomla:/sbin/nologin\n' ;;
        *) return 2 ;;
        esac
    }

    APACHE_RUN_USER='web-user'
    APACHE_RUN_GROUP='web-group'
    joomla_resolve_runtime_identity apache2-foreground

    assert_equal '1201' "$user" 'named Apache UID'
    assert_equal '1302' "$group" 'named Apache GID'
}

test_fpm_identity_uses_www_data() {
    # shellcheck source=../src/docker/docker-entrypoint.sh
    source "$ENTRYPOINT"

    id() {
        if [[ "${1:-}" == '-u' && "$#" -eq 1 ]]; then
            printf '0\n'
        elif [[ "${1:-}" == '-g' && "$#" -eq 1 ]]; then
            printf '0\n'
        elif [[ "${1:-}" == '-u' && "${2:-}" == 'www-data' ]]; then
            printf '82\n'
        else
            return 1
        fi
    }
    getent() {
        case "$1:$2" in
        group:www-data) printf 'www-data:x:82:\n' ;;
        passwd:82) printf 'www-data:x:82:82::/var/www:/sbin/nologin\n' ;;
        *) return 2 ;;
        esac
    }

    APACHE_RUN_USER='#1201'
    APACHE_RUN_GROUP='#1302'
    joomla_resolve_runtime_identity php-fpm

    assert_equal '82' "$user" 'FPM UID'
    assert_equal '82' "$group" 'FPM GID'
}

test_cli_failure_propagates() {
    # shellcheck source=../src/docker/docker-entrypoint.sh
    source "$ENTRYPOINT"

    php() {
        return 37
    }

    if joomla_run_cli cache:clean; then
        fail 'Joomla CLI failure was swallowed'
    fi
}

test_invalid_extension_inputs_fail() {
    # shellcheck source=../src/docker/docker-entrypoint.sh
    source "$ENTRYPOINT"

    if joomla_install_extension_via_url 'not-a-valid-url'; then
        fail 'invalid extension URL was accepted'
    fi
    if joomla_install_extension_via_path '/definitely/not/a/real/extension.zip'; then
        fail 'missing extension path was accepted'
    fi
}

test_ownership_repair_is_recursive_and_fatal() {
    # shellcheck source=../src/docker/docker-entrypoint.sh
    source "$ENTRYPOINT"

    local temp_dir
    local calls=''
    temp_dir="$(mktemp -d)"
    trap 'rm -rf "$temp_dir"' RETURN
    : > "${temp_dir}/configuration.php"

    uid=0
    user=1201
    group=1302
    JOOMLA_WEBROOT="$temp_dir"

    chown() {
        calls+="chown:$*;"
    }
    chmod() {
        calls+="chmod:$*;"
    }

    joomla_repair_webroot_ownership
    assert_contains "$calls" "chown:-R 1201:1302 ${temp_dir}" 'recursive ownership repair'
    assert_contains "$calls" "chmod:0444 ${temp_dir}/configuration.php" 'configuration mode repair'

    chown() {
        return 1
    }
    chmod() {
        fail 'chmod ran after failed chown'
    }
    if joomla_repair_webroot_ownership; then
        fail 'ownership repair failure was swallowed'
    fi

    chown() {
        return 0
    }
    chmod() {
        return 1
    }
    if joomla_repair_webroot_ownership; then
        fail 'configuration mode failure was swallowed'
    fi
}

create_mock_path() {
    local target_dir="$1"
    local command_name

    mkdir -p "$target_dir"
    for command_name in id php tar chown chmod apache2-foreground; do
        ln -s "$TEST_FILE" "${target_dir}/${command_name}"
    done
}

trace_line_number() {
    local trace_file="$1"
    local pattern="$2"

    awk -v pattern="$pattern" 'index($0, pattern) { line = NR } END { print line + 0 }' "$trace_file"
}

test_install_and_restart_finalizer_order() {
    local temp_dir
    local webroot
    local mock_bin
    local trace_file
    local jcb_zip
    local extension_zip
    local cli_line
    local final_chown_line
    local server_line

    temp_dir="$(mktemp -d)"
    trap 'rm -rf "$temp_dir"' RETURN
    webroot="${temp_dir}/html"
    mock_bin="${temp_dir}/bin"
    trace_file="${temp_dir}/trace"
    jcb_zip="${temp_dir}/jcb.zip"
    extension_zip="${temp_dir}/extension.zip"

    mkdir -p "$webroot"
    : > "$jcb_zip"
    : > "$extension_zip"
    : > "$trace_file"
    create_mock_path "$mock_bin"

    JOOMENGINE_ENTRYPOINT_MOCK=1 \
    JOOMENGINE_TRACE_FILE="$trace_file" \
    JOOMENGINE_TEST_WEBROOT="$webroot" \
    JOOMENGINE_TEST_JCB_ZIP="$jcb_zip" \
    PATH="${mock_bin}:$PATH" \
    JOOMLA_DB_HOST='database:3306' \
    JOOMLA_DB_PASSWORD='database-password' \
    APACHE_RUN_USER='1201' \
    APACHE_RUN_GROUP='1302' \
    JOOMLA_EXTENSIONS_PATHS="$extension_zip" \
    JOOMLA_CLI_COMMANDS='cache:clean --no-interaction' \
        bash -c '
            source "$1"
            export JOOMLA_WEBROOT="$JOOMENGINE_TEST_WEBROOT"
            export JCB_ZIP_PATH="$JOOMENGINE_TEST_JCB_ZIP"
            joomla_main apache2-foreground
        ' joomengine-entrypoint-test "$ENTRYPOINT"

    cli_line="$(trace_line_number "$trace_file" 'cache:clean --no-interaction')"
    final_chown_line="$(trace_line_number "$trace_file" "chown:-R 1201:1302 ${webroot}")"
    server_line="$(trace_line_number "$trace_file" 'apache2-foreground:')"

    [[ "$cli_line" -gt 0 ]] || fail 'configured CLI command was not run'
    [[ "$final_chown_line" -gt "$cli_line" ]] || \
        fail 'final ownership repair ran before the configured CLI command completed'
    [[ "$server_line" -gt "$final_chown_line" ]] || \
        fail 'Apache started before final ownership repair completed'
    assert_contains "$(<"$trace_file")" \
        "chmod:0444 ${webroot}/configuration.php" 'install configuration mode'
    assert_contains "$(<"$trace_file")" \
        '--owner 1201 --group 1302' 'fresh-volume archive ownership'
    assert_contains "$(<"$trace_file")" \
        'apache2-foreground::#1201:#1302' 'normalized Apache server identity'

    # The installer directory was removed by the first run. A normal restart
    # must still perform the recursive repair before Apache starts.
    : > "$trace_file"
    JOOMENGINE_ENTRYPOINT_MOCK=1 \
    JOOMENGINE_TRACE_FILE="$trace_file" \
    JOOMENGINE_TEST_WEBROOT="$webroot" \
    JOOMENGINE_TEST_JCB_ZIP="$jcb_zip" \
    PATH="${mock_bin}:$PATH" \
    JOOMLA_DB_HOST='database:3306' \
    JOOMLA_DB_PASSWORD='database-password' \
    APACHE_RUN_USER='#1201' \
    APACHE_RUN_GROUP='#1302' \
        bash -c '
            source "$1"
            export JOOMLA_WEBROOT="$JOOMENGINE_TEST_WEBROOT"
            export JCB_ZIP_PATH="$JOOMENGINE_TEST_JCB_ZIP"
            joomla_main apache2-foreground
        ' joomengine-entrypoint-test "$ENTRYPOINT"

    final_chown_line="$(trace_line_number "$trace_file" "chown:-R 1201:1302 ${webroot}")"
    server_line="$(trace_line_number "$trace_file" 'apache2-foreground:')"
    [[ "$final_chown_line" -gt 0 ]] || fail 'restart skipped recursive ownership repair'
    [[ "$server_line" -gt "$final_chown_line" ]] || \
        fail 'restart started Apache before ownership repair'

    # A synchronous Joomla CLI failure must still trigger the EXIT finalizer.
    mkdir -p "${webroot}/installation"
    : > "${webroot}/installation/joomla.php"
    : > "$trace_file"
    if JOOMENGINE_ENTRYPOINT_MOCK=1 \
        JOOMENGINE_TRACE_FILE="$trace_file" \
        JOOMENGINE_FAIL_PHP_MATCH='cache:clean' \
        JOOMENGINE_TEST_WEBROOT="$webroot" \
        JOOMENGINE_TEST_JCB_ZIP="$jcb_zip" \
        PATH="${mock_bin}:$PATH" \
        JOOMLA_DB_HOST='database:3306' \
        JOOMLA_DB_PASSWORD='database-password' \
        APACHE_RUN_USER='#1201' \
        APACHE_RUN_GROUP='#1302' \
        JOOMLA_CLI_COMMANDS='cache:clean --no-interaction' \
            bash -c '
                source "$1"
                export JOOMLA_WEBROOT="$JOOMENGINE_TEST_WEBROOT"
                export JCB_ZIP_PATH="$JOOMENGINE_TEST_JCB_ZIP"
                joomla_main apache2-foreground
            ' joomengine-entrypoint-test "$ENTRYPOINT"; then
        fail 'failed Joomla CLI command did not abort startup'
    fi

    cli_line="$(trace_line_number "$trace_file" 'cache:clean --no-interaction')"
    final_chown_line="$(trace_line_number "$trace_file" "chown:-R 1201:1302 ${webroot}")"
    server_line="$(trace_line_number "$trace_file" 'apache2-foreground:')"
    [[ "$final_chown_line" -gt "$cli_line" ]] || \
        fail 'EXIT finalizer did not repair ownership after CLI failure'
    [[ "$server_line" -eq 0 ]] || fail 'Apache started after Joomla CLI failure'
}

run_test 'numeric Apache UID/GID resolution' test_numeric_apache_identity
run_test 'named Apache UID/GID resolution' test_named_apache_identity
run_test 'FPM www-data identity resolution' test_fpm_identity_uses_www_data
run_test 'Joomla CLI failure propagation' test_cli_failure_propagates
run_test 'invalid extension input propagation' test_invalid_extension_inputs_fail
run_test 'recursive fatal ownership repair' test_ownership_repair_is_recursive_and_fatal
run_test 'install/restart finalizer ordering' test_install_and_restart_finalizer_order

printf '1..%d\n' "$tests_run"
if [[ "$failures" -ne 0 ]]; then
    printf '%d test(s) failed\n' "$failures" >&2
    exit 1
fi
