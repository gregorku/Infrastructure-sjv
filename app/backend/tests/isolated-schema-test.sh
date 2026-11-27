#!/usr/bin/env bash
# Isolated PostgreSQL 19.0 check for the ingest migration.
# Uses a disposable Docker container and network owned by this run via labels.
# It does not use the project Compose stack, init.sh, /docker-data, or a runtime .env.
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
BACKEND="${REPO_ROOT}/app/backend"
IMAGE="docker.io/library/postgres:19.0@sha256:bb6e70add742cd868fb62cb3b2f67d1dd2bdd2b65a521e778420748753687c60"

LABEL_TEST_KEY="sjv.isolated-schema-test"
LABEL_TEST_VALUE="1"
LABEL_RUN_KEY="sjv.isolated-schema-test.run"
LEGACY_CONTAINER="sjv-alembic-pg"
LEGACY_NETWORK="sjv-alembic-net"
LOCK_FILE="/tmp/sjv-isolated-schema-test.lock"

RUN_ID=""
CONTAINER=""
NETWORK=""
TEST_ROOT=""
OWNED_TEST_ROOT=""
CLEANUP_FAILED=0
CLEANUP_DONE=0
LOCK_RELEASED=0

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
if ! command -v docker >/dev/null 2>&1; then
    printf '%s\n' "docker is required for the isolated schema test." >&2
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "python3 is required for the isolated schema test." >&2
    exit 1
fi

is_local_docker_endpoint() {
    case "$1" in
        ""|unix://*|fd://*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

require_local_docker() {
    local ctx host ctx_env
    ctx_env="${DOCKER_CONTEXT-}"
    if ! ctx="$(docker context show 2>/dev/null)"; then
        printf '%s\n' "docker context show failed." >&2
        return 1
    fi
    if [[ -n "${ctx_env}" && "${ctx_env}" != "${ctx}" ]]; then
        printf '%s\n' "Refusing ambiguous Docker context (DOCKER_CONTEXT=${ctx_env}, active=${ctx})." >&2
        return 1
    fi
    if ! host="$(docker context inspect -f '{{.Endpoints.docker.Host}}' "${ctx}" 2>/dev/null)"; then
        printf '%s\n' "docker context inspect failed for '${ctx}'." >&2
        return 1
    fi
    if ! is_local_docker_endpoint "${host}"; then
        printf '%s\n' "Refusing Docker context '${ctx}' with endpoint '${host}'." >&2
        return 1
    fi
    if [[ -n "${DOCKER_HOST-}" ]]; then
        if ! is_local_docker_endpoint "${DOCKER_HOST}"; then
            printf '%s\n' "Refusing non-local DOCKER_HOST=${DOCKER_HOST}" >&2
            return 1
        fi
        if [[ -n "${host}" && "${DOCKER_HOST}" != "${host}" ]]; then
            printf '%s\n' "Refusing ambiguous Docker endpoint (DOCKER_HOST=${DOCKER_HOST}, context host=${host})." >&2
            return 1
        fi
    fi
    if ! docker info >/dev/null 2>&1; then
        printf '%s\n' "docker daemon is not reachable." >&2
        return 1
    fi
    return 0
}

# Hold an exclusive lock without following symlinks (O_NOFOLLOW).
# The lock FD stays open in a coprocess until cleanup closes its stdin.
acquire_run_lock() {
    local reply rc
    coproc LOCKHOLDER {
        python3 -c '
import errno
import fcntl
import os
import stat
import sys

path = sys.argv[1]
flags = os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW
try:
    fd = os.open(path, flags, 0o600)
except OSError as exc:
    if exc.errno == errno.ELOOP:
        sys.stderr.write("Refusing lock file: path is a symbolic link.\n")
        sys.exit(1)
    sys.stderr.write("Failed to open lock file %s: %s\n" % (path, exc))
    sys.exit(1)

try:
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode):
        sys.stderr.write("Refusing lock file: not a regular file.\n")
        sys.exit(1)
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.stderr.write(
        "Isolated schema test is already running (lock %s).\n" % path
    )
    sys.exit(2)
except OSError as exc:
    sys.stderr.write("Failed to lock %s: %s\n" % (path, exc))
    sys.exit(1)

sys.stdout.write("OK\n")
sys.stdout.flush()
try:
    sys.stdin.read()
finally:
    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
    except OSError:
        pass
    os.close(fd)
' "${LOCK_FILE}"
    }
    set +e
    read -r reply <&"${LOCKHOLDER[0]}"
    rc=$?
    set -e
    if [[ "${rc}" -ne 0 || "${reply}" != "OK" ]]; then
        set +e
        wait "${LOCKHOLDER_PID}"
        rc=$?
        set -e
        if [[ "${rc}" -eq 2 ]]; then
            exit 1
        fi
        printf '%s\n' "Failed to acquire isolated schema test lock (${LOCK_FILE})." >&2
        exit 1
    fi
}

release_run_lock() {
    if [[ "${LOCK_RELEASED}" -eq 1 ]]; then
        return 0
    fi
    LOCK_RELEASED=1
    if [[ -n "${LOCKHOLDER[1]-}" ]]; then
        eval "exec ${LOCKHOLDER[1]}>&-" || true
    fi
    if [[ -n "${LOCKHOLDER_PID-}" ]]; then
        set +e
        wait "${LOCKHOLDER_PID}"
        set -e
    fi
}

# Serialize the whole run, including cleanup. Lock file is never deleted.
acquire_run_lock
# Temporary traps until the full cleanup handler is installed below.
trap 'release_run_lock' EXIT
trap 'release_run_lock; exit 130' INT
trap 'release_run_lock; exit 143' TERM

# Daemon checks must succeed before create/delete.
if ! require_local_docker; then
    exit 1
fi

DOCKER_PROBE_ERROR=""
PROBE_RC=0

is_docker_not_found_error() {
    local msg="$1"
    # Match Docker's explicit missing-object messages only.
    # Do not treat a bare "not found" (e.g. context/daemon errors) as absence.
    # Also match: Error response from daemon: network <name> not found
    grep -qiE \
        'no such object:|no such container:|no such network:|error: no such (object|container|network)|network[[:space:]]+[^[:space:]]+[[:space:]]+not found' \
        <<<"${msg}"
}

# Probe a Docker container. Return: 0=exists, 1=absent, 2=inspect/daemon error.
probe_docker_container() {
    local name="$1"
    local err rc
    DOCKER_PROBE_ERROR=""
    set +e
    err="$(docker container inspect "${name}" 2>&1 >/dev/null)"
    rc=$?
    set -e
    if [[ "${rc}" -eq 0 ]]; then
        return 0
    fi
    DOCKER_PROBE_ERROR="${err}"
    if is_docker_not_found_error "${err}"; then
        return 1
    fi
    return 2
}

# Probe a Docker network. Return: 0=exists, 1=absent, 2=inspect/daemon error.
probe_docker_network() {
    local name="$1"
    local err rc
    DOCKER_PROBE_ERROR=""
    set +e
    err="$(docker network inspect "${name}" 2>&1 >/dev/null)"
    rc=$?
    set -e
    if [[ "${rc}" -eq 0 ]]; then
        return 0
    fi
    DOCKER_PROBE_ERROR="${err}"
    if is_docker_not_found_error "${err}"; then
        return 1
    fi
    return 2
}

# Capture probe status under set -e. Status 1 (absent) must not abort the script.
# Sets PROBE_RC to 0 (exists), 1 (absent), or 2 (error).
run_probe_container() {
    if probe_docker_container "$1"; then
        PROBE_RC=0
    else
        PROBE_RC=$?
    fi
}

run_probe_network() {
    if probe_docker_network "$1"; then
        PROBE_RC=0
    else
        PROBE_RC=$?
    fi
}

refuse_legacy_name() {
    local kind="$1"
    local name="$2"
    local detail="$3"
    printf '%s\n' "Refusing to proceed: ${kind} '${name}' exists (${detail})." >&2
    printf '%s\n' "This script never deletes the legacy fixed names. Inspect and remove manually if safe." >&2
    exit 1
}

assert_legacy_names_safe() {
    local label_test label_run
    if ! require_local_docker; then
        exit 1
    fi

    run_probe_container "${LEGACY_CONTAINER}"
    if [[ "${PROBE_RC}" -eq 2 ]]; then
        printf '%s\n' "Failed to inspect legacy container '${LEGACY_CONTAINER}': ${DOCKER_PROBE_ERROR}" >&2
        exit 1
    fi
    if [[ "${PROBE_RC}" -eq 0 ]]; then
        label_test="$(docker inspect -f "{{index .Config.Labels \"${LABEL_TEST_KEY}\"}}" "${LEGACY_CONTAINER}" 2>/dev/null || true)"
        label_run="$(docker inspect -f "{{index .Config.Labels \"${LABEL_RUN_KEY}\"}}" "${LEGACY_CONTAINER}" 2>/dev/null || true)"
        if [[ "${label_test}" != "${LABEL_TEST_VALUE}" || -z "${label_run}" ]]; then
            refuse_legacy_name "container" "${LEGACY_CONTAINER}" "missing required ownership labels"
        fi
        refuse_legacy_name "container" "${LEGACY_CONTAINER}" "legacy fixed name is not owned by this run"
    fi

    run_probe_network "${LEGACY_NETWORK}"
    if [[ "${PROBE_RC}" -eq 2 ]]; then
        printf '%s\n' "Failed to inspect legacy network '${LEGACY_NETWORK}': ${DOCKER_PROBE_ERROR}" >&2
        exit 1
    fi
    if [[ "${PROBE_RC}" -eq 0 ]]; then
        label_test="$(docker network inspect -f "{{index .Labels \"${LABEL_TEST_KEY}\"}}" "${LEGACY_NETWORK}" 2>/dev/null || true)"
        label_run="$(docker network inspect -f "{{index .Labels \"${LABEL_RUN_KEY}\"}}" "${LEGACY_NETWORK}" 2>/dev/null || true)"
        if [[ "${label_test}" != "${LABEL_TEST_VALUE}" || -z "${label_run}" ]]; then
            refuse_legacy_name "network" "${LEGACY_NETWORK}" "missing required ownership labels"
        fi
        refuse_legacy_name "network" "${LEGACY_NETWORK}" "legacy fixed name is not owned by this run"
    fi
}

assert_legacy_names_safe

RUN_ID="$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
CONTAINER="sjv-alembic-pg-${RUN_ID}"
NETWORK="sjv-alembic-net-${RUN_ID}"

# Create TEST_ROOT under a real directory (refuse TMPDIR that is a symlink).
TEST_ROOT="$(
    python3 -c '
import os
import stat
import sys
import tempfile

base = sys.argv[1]
try:
    info = os.lstat(base)
except OSError as exc:
    sys.stderr.write("Invalid TMPDIR %s: %s\n" % (base, exc))
    sys.exit(1)
if stat.S_ISLNK(info.st_mode):
    sys.stderr.write("Refusing TMPDIR that is a symbolic link: %s\n" % base)
    sys.exit(1)
if not stat.S_ISDIR(info.st_mode):
    sys.stderr.write("Refusing TMPDIR that is not a directory: %s\n" % base)
    sys.exit(1)
try:
    path = tempfile.mkdtemp(prefix="sjv-alembic-itest.", dir=base)
except OSError as exc:
    sys.stderr.write("Failed to create TEST_ROOT under %s: %s\n" % (base, exc))
    sys.exit(1)
if os.path.islink(path):
    os.rmdir(path)
    sys.stderr.write("Refusing TEST_ROOT that is a symbolic link.\n")
    sys.exit(1)
os.chmod(path, 0o700)
print(path)
' "${TMPDIR:-/tmp}"
)"
OWNED_TEST_ROOT="${TEST_ROOT}"
export TMPDIR="${TEST_ROOT}/tmp"
mkdir -p "${TMPDIR}"
chmod 700 "${TMPDIR}"

container_owned_by_this_run() {
    local name="$1"
    local label_test label_run rc
    set +e
    label_test="$(docker inspect -f "{{index .Config.Labels \"${LABEL_TEST_KEY}\"}}" "${name}" 2>/dev/null)"
    rc=$?
    set -e
    if [[ "${rc}" -ne 0 ]]; then
        return 1
    fi
    set +e
    label_run="$(docker inspect -f "{{index .Config.Labels \"${LABEL_RUN_KEY}\"}}" "${name}" 2>/dev/null)"
    rc=$?
    set -e
    if [[ "${rc}" -ne 0 ]]; then
        return 1
    fi
    [[ "${label_test}" == "${LABEL_TEST_VALUE}" && "${label_run}" == "${RUN_ID}" ]]
}

network_owned_by_this_run() {
    local name="$1"
    local label_test label_run rc
    set +e
    label_test="$(docker network inspect -f "{{index .Labels \"${LABEL_TEST_KEY}\"}}" "${name}" 2>/dev/null)"
    rc=$?
    set -e
    if [[ "${rc}" -ne 0 ]]; then
        return 1
    fi
    set +e
    label_run="$(docker network inspect -f "{{index .Labels \"${LABEL_RUN_KEY}\"}}" "${name}" 2>/dev/null)"
    rc=$?
    set -e
    if [[ "${rc}" -ne 0 ]]; then
        return 1
    fi
    [[ "${label_test}" == "${LABEL_TEST_VALUE}" && "${label_run}" == "${RUN_ID}" ]]
}

remove_owned_container() {
    local name="$1"
    local rc err
    if ! require_local_docker; then
        printf '%s\n' "Refusing to remove container '${name}': Docker daemon check failed before inspect/delete." >&2
        CLEANUP_FAILED=1
        return 1
    fi
    run_probe_container "${name}"
    if [[ "${PROBE_RC}" -eq 1 ]]; then
        return 0
    fi
    if [[ "${PROBE_RC}" -eq 2 ]]; then
        printf '%s\n' "Cannot reliably verify container '${name}' before delete: ${DOCKER_PROBE_ERROR}" >&2
        CLEANUP_FAILED=1
        return 1
    fi
    if ! container_owned_by_this_run "${name}"; then
        printf '%s\n' "Refusing to remove container '${name}': labels do not match this run." >&2
        CLEANUP_FAILED=1
        return 1
    fi
    if ! require_local_docker; then
        printf '%s\n' "Refusing to remove container '${name}': Docker daemon check failed before delete." >&2
        CLEANUP_FAILED=1
        return 1
    fi
    set +e
    err="$(docker rm -f "${name}" 2>&1 >/dev/null)"
    rc=$?
    set -e
    if [[ "${rc}" -eq 0 ]]; then
        return 0
    fi
    if is_docker_not_found_error "${err}"; then
        return 0
    fi
    printf '%s\n' "Failed to remove owned container '${name}': ${err}" >&2
    CLEANUP_FAILED=1
    return 1
}

remove_owned_network() {
    local name="$1"
    local rc err
    if ! require_local_docker; then
        printf '%s\n' "Refusing to remove network '${name}': Docker daemon check failed before inspect/delete." >&2
        CLEANUP_FAILED=1
        return 1
    fi
    run_probe_network "${name}"
    if [[ "${PROBE_RC}" -eq 1 ]]; then
        return 0
    fi
    if [[ "${PROBE_RC}" -eq 2 ]]; then
        printf '%s\n' "Cannot reliably verify network '${name}' before delete: ${DOCKER_PROBE_ERROR}" >&2
        CLEANUP_FAILED=1
        return 1
    fi
    if ! network_owned_by_this_run "${name}"; then
        printf '%s\n' "Refusing to remove network '${name}': labels do not match this run." >&2
        CLEANUP_FAILED=1
        return 1
    fi
    if ! require_local_docker; then
        printf '%s\n' "Refusing to remove network '${name}': Docker daemon check failed before delete." >&2
        CLEANUP_FAILED=1
        return 1
    fi
    set +e
    err="$(docker network rm "${name}" 2>&1 >/dev/null)"
    rc=$?
    set -e
    if [[ "${rc}" -eq 0 ]]; then
        return 0
    fi
    if is_docker_not_found_error "${err}"; then
        return 0
    fi
    printf '%s\n' "Failed to remove owned network '${name}': ${err}" >&2
    CLEANUP_FAILED=1
    return 1
}

remove_test_root() {
    if [[ -z "${TEST_ROOT}" || -z "${OWNED_TEST_ROOT}" ]]; then
        return 0
    fi
    if [[ "${TEST_ROOT}" != "${OWNED_TEST_ROOT}" ]]; then
        printf '%s\n' "Refusing to delete unexpected TEST_ROOT='${TEST_ROOT}'." >&2
        CLEANUP_FAILED=1
        return 1
    fi
    case "${OWNED_TEST_ROOT}" in
        */sjv-alembic-itest.*)
            ;;
        *)
            printf '%s\n' "Refusing to delete unexpected TEST_ROOT='${OWNED_TEST_ROOT}'." >&2
            CLEANUP_FAILED=1
            return 1
            ;;
    esac
    if [[ ! -e "${OWNED_TEST_ROOT}" ]]; then
        return 0
    fi
    if ! python3 -c '
import os
import stat
import sys
import shutil

path = sys.argv[1]
try:
    info = os.lstat(path)
except FileNotFoundError:
    sys.exit(0)
except OSError as exc:
    sys.stderr.write("Failed to stat TEST_ROOT %s: %s\n" % (path, exc))
    sys.exit(1)
if stat.S_ISLNK(info.st_mode):
    sys.stderr.write("Refusing to delete TEST_ROOT that is a symbolic link: %s\n" % path)
    sys.exit(1)
if not stat.S_ISDIR(info.st_mode):
    sys.stderr.write("Refusing to delete TEST_ROOT that is not a directory: %s\n" % path)
    sys.exit(1)
basename = os.path.basename(path)
if not basename.startswith("sjv-alembic-itest."):
    sys.stderr.write("Refusing to delete unexpected TEST_ROOT name: %s\n" % path)
    sys.exit(1)
shutil.rmtree(path)
' "${OWNED_TEST_ROOT}"; then
        printf '%s\n' "Failed to remove TEST_ROOT='${OWNED_TEST_ROOT}'." >&2
        CLEANUP_FAILED=1
        return 1
    fi
    return 0
}

cleanup() {
    local status=$?
    local skip_network_removal=0
    if [[ "${CLEANUP_DONE}" -eq 1 ]]; then
        return 0
    fi
    CLEANUP_DONE=1
    trap - EXIT INT TERM

    if ! require_local_docker; then
        printf '%s\n' "Skipping Docker object cleanup: daemon check failed before inspect." >&2
        CLEANUP_FAILED=1
        skip_network_removal=1
    elif [[ -n "${CONTAINER}" ]]; then
        run_probe_container "${CONTAINER}"
        if [[ "${PROBE_RC}" -eq 2 ]]; then
            printf '%s\n' "Cannot reliably verify container '${CONTAINER}' during cleanup: ${DOCKER_PROBE_ERROR}" >&2
            CLEANUP_FAILED=1
            skip_network_removal=1
        elif [[ "${PROBE_RC}" -eq 0 ]]; then
            if container_owned_by_this_run "${CONTAINER}"; then
                docker logs "${CONTAINER}" > "${TEST_ROOT}/postgres.log" 2>&1 || true
            fi
            # If container delete is refused, do not touch the network on a
            # potentially different Docker endpoint.
            if ! remove_owned_container "${CONTAINER}"; then
                skip_network_removal=1
            fi
        fi
    fi

    if [[ "${skip_network_removal}" -eq 1 ]]; then
        if [[ -n "${NETWORK}" ]]; then
            printf '%s\n' "Skipping network '${NETWORK}' removal after container cleanup failure or unreliable container state." >&2
            CLEANUP_FAILED=1
        fi
    elif [[ -n "${NETWORK}" ]]; then
        if ! remove_owned_network "${NETWORK}"; then
            :
        fi
    fi

    if [[ "${status}" -ne 0 && -n "${TEST_ROOT}" && -f "${TEST_ROOT}/postgres.log" ]]; then
        show_log "${TEST_ROOT}/postgres.log"
    fi
    if [[ -n "${TEST_ROOT}" && -d "${TEST_ROOT}" ]]; then
        find "${TEST_ROOT}" -maxdepth 1 -type f \( -name 'secret-*' -o -name 'url-*' -o -name 'env.file' \) -delete || true
    fi
    if [[ "${status}" -eq 0 ]]; then
        remove_test_root || true
    fi

    if [[ "${CLEANUP_FAILED}" -ne 0 && "${status}" -eq 0 ]]; then
        status=1
    fi
    # Release the flock only after Docker/TEST_ROOT cleanup finished.
    release_run_lock
    exit "${status}"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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

if ! require_local_docker; then
    exit 1
fi

run_probe_network "${NETWORK}"
if [[ "${PROBE_RC}" -eq 0 ]]; then
    printf '%s\n' "Test network ${NETWORK} already exists." >&2
    exit 1
fi
if [[ "${PROBE_RC}" -eq 2 ]]; then
    printf '%s\n' "Failed to inspect test network '${NETWORK}' before create: ${DOCKER_PROBE_ERROR}" >&2
    exit 1
fi

run_probe_container "${CONTAINER}"
if [[ "${PROBE_RC}" -eq 0 ]]; then
    printf '%s\n' "Test container ${CONTAINER} already exists." >&2
    exit 1
fi
if [[ "${PROBE_RC}" -eq 2 ]]; then
    printf '%s\n' "Failed to inspect test container '${CONTAINER}' before create: ${DOCKER_PROBE_ERROR}" >&2
    exit 1
fi

docker network create \
    --label "${LABEL_TEST_KEY}=${LABEL_TEST_VALUE}" \
    --label "${LABEL_RUN_KEY}=${RUN_ID}" \
    "${NETWORK}" >/dev/null

run_logged "${TEST_ROOT}/pull.log" docker pull "${IMAGE}"

docker run -d \
    --name "${CONTAINER}" \
    --label "${LABEL_TEST_KEY}=${LABEL_TEST_VALUE}" \
    --label "${LABEL_RUN_KEY}=${RUN_ID}" \
    --network "${NETWORK}" \
    --env-file "${TEST_ROOT}/env.file" \
    --tmpfs /var/lib/postgresql:mode=1777 \
    -p 127.0.0.1::5432 \
    -v "${REPO_ROOT}/postgresql/docker-entrypoint-initdb.d:/docker-entrypoint-initdb.d:ro" \
    "${IMAGE}" >/dev/null

if ! container_owned_by_this_run "${CONTAINER}"; then
    printf '%s\n' "Created container is missing ownership labels." >&2
    exit 1
fi
if ! network_owned_by_this_run "${NETWORK}"; then
    printf '%s\n' "Created network is missing ownership labels." >&2
    exit 1
fi

ready=0
for attempt in $(seq 1 90); do
    if docker exec "${CONTAINER}" pg_isready -U sjv_bootstrap -d sjv >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 1
done
if [[ "${ready}" -ne 1 ]]; then
    printf '%s\n' "PostgreSQL did not become ready after ${attempt} attempts." >&2
    exit 1
fi

mapping="$(docker port "${CONTAINER}" 5432/tcp)"
mapping="${mapping%%$'\n'*}"
port="${mapping##*:}"
if [[ -z "${port}" || ! "${port}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "Could not resolve published PostgreSQL port." >&2
    exit 1
fi

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

run_recovery_unit_tests() {
    set +e
    (
        cd "${BACKEND}"
        PYTHONPATH="${BACKEND}" python3 tests/test_recovery.py
    ) > "${TEST_ROOT}/recovery-unit.log" 2>&1
    local status=$?
    set -e
    show_log "${TEST_ROOT}/recovery-unit.log"
    if [[ "${status}" -ne 0 ]]; then
        exit "${status}"
    fi
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
    set +e
    (
        cd "${BACKEND}"
        PYTHONPATH="${BACKEND}" SJV_DATABASE_URL="$(cat "${urlfile}")" python3 tests/recovery_tests.py
    ) > "${TEST_ROOT}/recovery-${database}.log" 2>&1
    local recovery_status=$?
    set -e
    show_log "${TEST_ROOT}/recovery-${database}.log"
    if [[ "${recovery_status}" -ne 0 ]]; then
        exit "${recovery_status}"
    fi
    rm -f "${urlfile}"
}

run_recovery_unit_tests

migrate sjv

docker exec "${CONTAINER}" psql -U sjv_bootstrap -d postgres -v ON_ERROR_STOP=1 \
    -c "CREATE DATABASE sjv_repeat OWNER sjv_owner" >/dev/null
docker exec "${CONTAINER}" psql -U sjv_bootstrap -d sjv_repeat -v ON_ERROR_STOP=1 \
    -c "REVOKE ALL ON DATABASE sjv_repeat FROM PUBLIC" \
    -c "GRANT CONNECT ON DATABASE sjv_repeat TO sjv_owner, sjv_api, sjv_collector, sjv_worker, sjv_maintenance, sjv_readonly, pgbackrest" \
    -c "REVOKE ALL ON SCHEMA public FROM PUBLIC" \
    -c "GRANT USAGE, CREATE ON SCHEMA public TO sjv_owner" \
    -c "GRANT USAGE ON SCHEMA public TO sjv_api, sjv_collector, sjv_worker, sjv_maintenance, sjv_readonly, pgbackrest" >/dev/null

migrate sjv_repeat
printf '%s\n' "Isolated ingest migration passed on two empty databases."
