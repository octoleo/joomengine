#!/usr/bin/env bash
# Exercise a real first deployment and restart of a freshly built Apache image.
# Usage: tests/image-smoke-test.sh IMAGE standard|mcp
set -euo pipefail

if [[ $# -ne 2 || ( "$2" != standard && "$2" != mcp ) ]]; then
    echo "Usage: $0 IMAGE standard|mcp" >&2
    exit 2
fi

image="$1"
flavor="$2"
timeout_seconds="${JOOMENGINE_SMOKE_TIMEOUT_SECONDS:-900}"
if [[ ! "$timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
    echo 'JOOMENGINE_SMOKE_TIMEOUT_SECONDS must be a positive integer.' >&2
    exit 2
fi
for command in docker curl; do
    command -v "$command" >/dev/null || {
        echo "Missing smoke-test dependency: $command" >&2
        exit 1
    }
done

test_id="joomengine-smoke-${BASHPID}-${RANDOM}"
network="$test_id"
database="${test_id}-db"
application="${test_id}-app"
# These disposable credentials are limited to the isolated test network. No
# database ports are published, and all containers and volumes are removed.
database_password="smoke-${RANDOM}-${RANDOM}-database"
root_password="smoke-${RANDOM}-${RANDOM}-root"

cleanup() {
    local status=$?
    trap - EXIT
    set +e
    if [[ "$status" -ne 0 ]]; then
        echo 'Image smoke failed; application and database diagnostics follow.' >&2
        docker inspect --format '{{json .State}}' "$application" >&2
        docker logs --tail 250 "$application" >&2
        docker logs --tail 100 "$database" >&2
    fi
    docker rm --force --volumes "$application" "$database" >/dev/null 2>&1
    docker network rm "$network" >/dev/null 2>&1
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

container_running() {
    [[ "$(docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null)" == true ]]
}

database_query() {
    docker exec --env "MYSQL_PWD=$database_password" "$database" \
        mariadb --user=joomengine --database=joomengine \
        --batch --skip-column-names --execute "$1"
}

assert_query() {
    local expected="$1"
    local query="$2"
    local description="$3"
    local actual
    actual="$(database_query "$query")"
    [[ "$actual" == "$expected" ]] ||
        fail "$description (expected $expected; received $actual)"
}

wait_for_http() {
    local phase="$1"
    local http_port
    local deadline=$((SECONDS + timeout_seconds))
    local next_progress=$((SECONDS + 30))
    # Docker may assign another ephemeral host port when a container restarts.
    # Read the current mapping for each phase rather than retaining the first.
    http_port="$(docker inspect --format '{{(index (index .NetworkSettings.Ports "80/tcp") 0).HostPort}}' "$application")"
    [[ "$http_port" =~ ^[0-9]+$ ]] || fail "Apache port was not published during $phase"
    echo "Checking $flavor $phase on HTTP port $http_port..."
    while (( SECONDS < deadline )); do
        container_running "$application" || fail "Application exited during $phase"
        if curl --fail --silent --output /dev/null --max-time 5 \
            "http://127.0.0.1:${http_port}/administrator/"; then
            return 0
        fi
        if (( SECONDS >= next_progress )); then
            echo "Waiting for $flavor $phase to finish..."
            next_progress=$((SECONDS + 30))
        fi
        sleep 2
    done
    fail "Timed out after ${timeout_seconds}s waiting for $phase"
}

verify_extensions() {
    assert_query 1 \
        "SELECT COUNT(*) FROM joom_extensions WHERE type='component' AND element='com_componentbuilder' AND enabled=1;" \
        'JCB component must be installed and enabled'

    if [[ "$flavor" == standard ]]; then
        assert_query 0 \
            "SELECT COUNT(*) FROM joom_extensions WHERE element IN ('pkg_joomengine_mcp','com_joomengine_mcp','joomengine_mcp');" \
            'Standard image must not install MCP'
        return
    fi

    assert_query 1 \
        "SELECT COUNT(*) FROM joom_extensions WHERE type='package' AND element='pkg_joomengine_mcp';" \
        'MCP package must be installed exactly once'
    assert_query 1 \
        "SELECT COUNT(*) FROM joom_extensions WHERE type='component' AND element='com_joomengine_mcp' AND enabled=1;" \
        'MCP component must be installed and enabled'
    for folder in console webservices; do
        assert_query 1 \
            "SELECT COUNT(*) FROM joom_extensions WHERE type='plugin' AND element='joomengine_mcp' AND folder='$folder' AND enabled=1;" \
            "MCP $folder plugin must be installed and enabled"
    done
    assert_query 3 \
        "SELECT COUNT(*) FROM joom_extensions AS child JOIN joom_extensions AS parent ON child.package_id=parent.extension_id WHERE parent.type='package' AND parent.element='pkg_joomengine_mcp' AND (child.element='com_joomengine_mcp' OR (child.element='joomengine_mcp' AND child.folder IN ('console','webservices')));" \
        'All three MCP extensions must belong to the installed package'
}

extension_snapshot() {
    database_query \
        "SELECT extension_id,type,element,folder,enabled,package_id,manifest_cache FROM joom_extensions WHERE element IN ('com_componentbuilder','pkg_joomengine_mcp','com_joomengine_mcp','joomengine_mcp') ORDER BY extension_id;"
}

docker network create "$network" >/dev/null
docker run --detach --name "$database" --network "$network" --network-alias database \
    --env "MARIADB_ROOT_PASSWORD=$root_password" \
    --env MARIADB_DATABASE=joomengine --env MARIADB_USER=joomengine \
    --env "MARIADB_PASSWORD=$database_password" \
    mariadb:11.4 >/dev/null

database_deadline=$((SECONDS + 120))
until docker exec "$database" healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1; do
    container_running "$database" || fail 'Database exited before it was ready'
    (( SECONDS < database_deadline )) || fail 'Database did not become ready within 120 seconds'
    sleep 2
done

echo "Starting $flavor first deployment..."
docker run --detach --name "$application" --network "$network" \
    --platform linux/amd64 --publish 127.0.0.1::80 \
    --env JOOMLA_DB_HOST=database --env JOOMLA_DB_USER=joomengine \
    --env JOOMLA_DB_NAME=joomengine --env JOOMLA_DB_PREFIX=joom_ \
    --env "JOOMLA_DB_PASSWORD=$database_password" \
    --env JOOMLA_SITE_NAME='JoomEngine deployment smoke test' \
    --env JOOMLA_ADMIN_USER='Smoke Test Administrator' \
    --env JOOMLA_ADMIN_USERNAME=smokeadmin \
    --env JOOMLA_ADMIN_PASSWORD='Disposable-Smoke-Password-2026!' \
    --env JOOMLA_ADMIN_EMAIL=smoke@example.com \
    "$image" >/dev/null

wait_for_http 'first deployment'
verify_extensions
before_restart="$(extension_snapshot)"

# Make the original installation inputs unusable after success. A restart
# must run the installed site and must not invoke either package installer
# again. This checks observable behavior without relying on marker names.
docker exec "$application" sh -eu -c '
    printf "This archive must never be installed again.\n" > /usr/src/joomengine/jcb.zip
    if [ -f /usr/src/joomengine/mcp.zip ]; then
        printf "This archive must never be installed again.\n" > /usr/src/joomengine/mcp.zip
    fi
'
echo "Starting $flavor restart after successful first deployment..."
docker restart --time 20 "$application" >/dev/null
wait_for_http restart
verify_extensions
[[ "$(extension_snapshot)" == "$before_restart" ]] ||
    fail 'Extension registration or installed versions changed during restart'

echo "PASS: $flavor first deployment, extension registration and restart without reinstall"
