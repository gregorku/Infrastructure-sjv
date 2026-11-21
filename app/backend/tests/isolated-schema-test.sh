#!/usr/bin/env bash
# Isolated PostgreSQL 19.0 check for the ingest migration.
# It does not use the project Compose, init.sh, /docker-data, or a runtime .env.
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
BACKEND="${REPO_ROOT}/app/backend"
IMAGE="docker.io/library/postgres:19.0@sha256:bb6e70add742cd868fb62cb3b2f67d1dd2bdd2b65a521e778420748753687c60"
TEST_ROOT="/tmp/sjv-alembic-itest"
CONTAINER="sjv-alembic-pg"
NETWORK="sjv-alembic-net"

if [[ "${REPO_ROOT}" == /docker-data || "${REPO_ROOT}" == /docker-data/* ]]; then
    printf '%s\n' "Refusing to run from /docker-data." >&2
    exit 1
fi
if [[ -n "${SJV_DATABASE_URL-}" ]]; then
    printf '%s\n' "Refusing a database URL from the environment." >&2
    exit 1
fi
if [[ ! -d "${REPO_ROOT}/postgresql/docker-entrypoint-initdb.d" ]]; then
    printf '%s\n' "Role init scripts are missing." >&2
    exit 1
fi

if [[ -d "${TEST_ROOT}/home" ]]; then
    HOME="${TEST_ROOT}/home" XDG_DATA_HOME="${TEST_ROOT}/xdg" podman rm -f -a >/dev/null 2>&1 || true
    HOME="${TEST_ROOT}/home" XDG_DATA_HOME="${TEST_ROOT}/xdg" podman unshare rm -rf "${TEST_ROOT}" >/dev/null 2>&1 || true
fi
removed=0
for attempt in 1 2 3 4 5; do
    if rm -rf "${TEST_ROOT}"; then
        removed=1
        break
    fi
    sleep 1
done
if [[ "${removed}" -ne 1 ]]; then
    printf '%s\n' "Could not remove the previous test directory." >&2
    exit 1
fi
mkdir -p "${TEST_ROOT}/home" "${TEST_ROOT}/xdg" "${TEST_ROOT}/tmp"
export HOME="${TEST_ROOT}/home"
export XDG_DATA_HOME="${TEST_ROOT}/xdg"
export TMPDIR="${TEST_ROOT}/tmp"
unset CONTAINERS_CONF
unset CONTAINERS_STORAGE_CONF
mkdir -p "${HOME}/.config/containers"
cat > "${HOME}/.config/containers/policy.json" <<'EOF'
{"default":[{"type":"insecureAcceptAnything"}]}
EOF
cat > "${TEST_ROOT}/registries.conf" <<'EOF'
unqualified-search-registries = ["docker.io"]
EOF
export CONTAINERS_REGISTRIES_CONF="${TEST_ROOT}/registries.conf"

cleanup() {
    local status=$?
    if podman container exists "${CONTAINER}" >/dev/null 2>&1; then
        podman logs "${CONTAINER}" > "${TEST_ROOT}/postgres.log" 2>&1 || true
        podman rm -f "${CONTAINER}" >/dev/null 2>&1 || true
    fi
    podman network rm "${NETWORK}" >/dev/null 2>&1 || true
    if [[ "${status}" -ne 0 && -f "${TEST_ROOT}/postgres.log" ]]; then
        show_log "${TEST_ROOT}/postgres.log"
    fi
    if [[ -d "${TEST_ROOT}" ]]; then
        find "${TEST_ROOT}" -maxdepth 1 -type f \( -name 'secret-*' -o -name 'url-*' -o -name 'env.file' \) -delete
    fi
    if [[ "${status}" -eq 0 ]]; then
        local attempt
        for attempt in 1 2 3 4 5; do
            podman unshare rm -rf "${TEST_ROOT}" >/dev/null 2>&1 || true
            rm -rf "${TEST_ROOT}" >/dev/null 2>&1 || true
            if [[ ! -e "${TEST_ROOT}" ]]; then
                break
            fi
            sleep 1
        done
    fi
}
trap cleanup EXIT

show_log() {
    local file="$1"
    local secret
    local leaked=0
    if [[ ! -f "${file}" ]]; then
        return 0
    fi
    for secret in "${TEST_ROOT}"/secret-*; do
        [[ -e "${secret}" ]] || continue
        if grep -F -q -f "${secret}" "${file}"; then
            leaked=1
            break
        fi
    done
    if [[ "${leaked}" -eq 1 ]]; then
        printf '%s\n' "Log withheld because a password appeared in it." >&2
        return 0
    fi
    cat "${file}" >&2
}

run_logged() {
    local logfile="$1"
    shift
    set +e
    "$@" > "${logfile}" 2>&1
    local status=$?
    set -e
    if [[ "${status}" -ne 0 ]]; then
        show_log "${logfile}"
        exit "${status}"
    fi
}

write_secret() {
    local name="$1"
    local path="${TEST_ROOT}/secret-${name}"
    python3 -c 'import secrets; print(secrets.token_hex(24), end="")' > "${path}"
    chmod 600 "${path}"
    local length
    length="$(wc -c < "${path}")"
    if [[ "${length}" -ne 48 ]]; then
        printf '%s\n' "Password generation failed." >&2
        exit 1
    fi
}

write_secret bootstrap
write_secret owner
write_secret api
write_secret collector
write_secret worker
write_secret maintenance
write_secret readonly

{
    printf '%s\n' "POSTGRES_USER=sjv_bootstrap"
    printf '%s=' "POSTGRES_PASSWORD"
    cat "${TEST_ROOT}/secret-bootstrap"
    printf '\n'
    printf '%s\n' "POSTGRES_DB=sjv"
    printf '%s=' "POSTGRES_SJV_OWNER_PASSWORD"
    cat "${TEST_ROOT}/secret-owner"
    printf '\n'
    printf '%s=' "POSTGRES_SJV_API_PASSWORD"
    cat "${TEST_ROOT}/secret-api"
    printf '\n'
    printf '%s=' "POSTGRES_SJV_COLLECTOR_PASSWORD"
    cat "${TEST_ROOT}/secret-collector"
    printf '\n'
    printf '%s=' "POSTGRES_SJV_WORKER_PASSWORD"
    cat "${TEST_ROOT}/secret-worker"
    printf '\n'
    printf '%s=' "POSTGRES_SJV_MAINTENANCE_PASSWORD"
    cat "${TEST_ROOT}/secret-maintenance"
    printf '\n'
    printf '%s=' "POSTGRES_SJV_READONLY_PASSWORD"
    cat "${TEST_ROOT}/secret-readonly"
    printf '\n'
} > "${TEST_ROOT}/env.file"
chmod 600 "${TEST_ROOT}/env.file"

podman network create "${NETWORK}" >/dev/null
podman pull "${IMAGE}" >/dev/null
podman run -d \
    --name "${CONTAINER}" \
    --network "${NETWORK}" \
    --env-file "${TEST_ROOT}/env.file" \
    --tmpfs /var/lib/postgresql:mode=1777 \
    -p 127.0.0.1::5432 \
    -v "${REPO_ROOT}/postgresql/docker-entrypoint-initdb.d:/docker-entrypoint-initdb.d:ro" \
    "${IMAGE}" >/dev/null

ready=0
for attempt in $(seq 1 90); do
    if podman exec "${CONTAINER}" pg_isready -U sjv_bootstrap -d sjv >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 1
done
if [[ "${ready}" -ne 1 ]]; then
    printf '%s\n' "PostgreSQL did not become ready after ${attempt} attempts." >&2
    exit 1
fi

mapping="$(podman port "${CONTAINER}" 5432/tcp)"
mapping="${mapping%%$'\n'*}"
port="${mapping##*:}"

write_url() {
    local database="$1"
    local target="$2"
    DB_NAME="${database}" PORT="${port}" SECRET_FILE="${TEST_ROOT}/secret-bootstrap" URL_FILE="${target}" \
        python3 - <<'PY'
import os
from pathlib import Path
from urllib.parse import quote

password = Path(os.environ["SECRET_FILE"]).read_text(encoding="utf-8")
url = (
    "postgresql+psycopg://sjv_bootstrap:"
    + quote(password)
    + "@127.0.0.1:"
    + os.environ["PORT"]
    + "/"
    + os.environ["DB_NAME"]
)
Path(os.environ["URL_FILE"]).write_text(url, encoding="utf-8")
PY
    chmod 600 "${target}"
}

migrate() {
    local database="$1"
    local urlfile="${TEST_ROOT}/url-${database}"
    write_url "${database}" "${urlfile}"
    local upgrade_log="${TEST_ROOT}/upgrade-${database}.log"
    local check_log="${TEST_ROOT}/check-${database}.log"
    set +e
    (
        cd "${BACKEND}"
        SJV_DATABASE_URL="$(cat "${urlfile}")" alembic -c alembic.ini upgrade head
    ) > "${upgrade_log}" 2>&1
    local upgrade_status=$?
    set -e
    if [[ "${upgrade_status}" -ne 0 ]]; then
        show_log "${upgrade_log}"
        exit "${upgrade_status}"
    fi
    set +e
    (
        cd "${BACKEND}"
        SJV_DATABASE_URL="$(cat "${urlfile}")" alembic -c alembic.ini check
    ) > "${check_log}" 2>&1
    local check_status=$?
    set -e
    if [[ "${check_status}" -ne 0 ]]; then
        show_log "${check_log}"
        exit "${check_status}"
    fi
    local downgrade_log="${TEST_ROOT}/downgrade-${database}.log"
    set +e
    (
        cd "${BACKEND}"
        SJV_DATABASE_URL="$(cat "${urlfile}")" alembic -c alembic.ini downgrade -1
    ) > "${downgrade_log}" 2>&1
    local downgrade_status=$?
    set -e
    if [[ "${downgrade_status}" -eq 0 ]] || ! grep -q 'forward-only' "${downgrade_log}"; then
        printf '%s\n' "Downgrade was not refused as forward-only." >&2
        show_log "${downgrade_log}"
        exit 1
    fi
    set +e
    (
        cd "${BACKEND}"
        PYTHONPATH="${BACKEND}" SJV_DATABASE_URL="$(cat "${urlfile}")" python3 tests/schema_tests.py
    ) > "${TEST_ROOT}/schema-${database}.log" 2>&1
    local schema_status=$?
    set -e
    show_log "${TEST_ROOT}/schema-${database}.log"
    if [[ "${schema_status}" -ne 0 ]]; then
        exit "${schema_status}"
    fi
    set +e
    (
        cd "${BACKEND}"
        PYTHONPATH="${BACKEND}" SJV_DATABASE_URL="$(cat "${urlfile}")" python3 tests/ingest_accept_tests.py
    ) > "${TEST_ROOT}/accept-${database}.log" 2>&1
    local accept_status=$?
    set -e
    show_log "${TEST_ROOT}/accept-${database}.log"
    if [[ "${accept_status}" -ne 0 ]]; then
        exit "${accept_status}"
    fi
    set +e
    (
        cd "${BACKEND}"
        PYTHONPATH="${BACKEND}" SJV_DATABASE_URL="$(cat "${urlfile}")" python3 tests/retention_tests.py
    ) > "${TEST_ROOT}/retention-${database}.log" 2>&1
    local retention_status=$?
    set -e
    show_log "${TEST_ROOT}/retention-${database}.log"
    if [[ "${retention_status}" -ne 0 ]]; then
        exit "${retention_status}"
    fi
    rm -f "${urlfile}"
}

migrate sjv

podman exec "${CONTAINER}" psql -U sjv_bootstrap -d postgres -v ON_ERROR_STOP=1 \
    -c "CREATE DATABASE sjv_repeat OWNER sjv_owner" >/dev/null
podman exec "${CONTAINER}" psql -U sjv_bootstrap -d sjv_repeat -v ON_ERROR_STOP=1 \
    -c "REVOKE ALL ON DATABASE sjv_repeat FROM PUBLIC" \
    -c "GRANT CONNECT ON DATABASE sjv_repeat TO sjv_owner, sjv_api, sjv_collector, sjv_worker, sjv_maintenance, sjv_readonly, pgbackrest" \
    -c "REVOKE ALL ON SCHEMA public FROM PUBLIC" \
    -c "GRANT USAGE, CREATE ON SCHEMA public TO sjv_owner" \
    -c "GRANT USAGE ON SCHEMA public TO sjv_api, sjv_collector, sjv_worker, sjv_maintenance, sjv_readonly, pgbackrest" >/dev/null

migrate sjv_repeat
printf '%s\n' "Isolated ingest migration passed on two empty databases."
