#!/usr/bin/env bash
# Isolated PostgreSQL 19.0 check for the ingest migration.
# Uses disposable Docker objects owned by this run via labels:
#   - temporary PostgreSQL 19.0 container and network
#   - temporary Python test image built from app/backend/Dockerfile.test
# Python tests and Alembic run only inside that test image (no host uv/pip/alembic).
# It does not use the project Compose stack, init.sh, /docker-data, or a runtime .env.
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
BACKEND="${REPO_ROOT}/app/backend"
IMAGE="docker.io/library/postgres:19.0@sha256:bb6e70add742cd868fb62cb3b2f67d1dd2bdd2b65a521e778420748753687c60"
DOCKERFILE_TEST="${BACKEND}/Dockerfile.test"

LABEL_TEST_KEY="sjv.isolated-schema-test"
LABEL_TEST_VALUE="1"
LABEL_RUN_KEY="sjv.isolated-schema-test.run"
LEGACY_CONTAINER="sjv-alembic-pg"
LEGACY_NETWORK="sjv-alembic-net"
LOCK_FILE="/tmp/sjv-isolated-schema-test.lock"

RUN_ID=""
CONTAINER=""
NETWORK=""
TEST_IMAGE=""
OWNED_TEST_IMAGE=""
OWNED_TEST_IMAGE_ID=""
BUILT_TEST_IMAGE=0
PY_RUN_CONTAINER=""
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
    printf '%s\n' "python3 is required for lock, secrets and path helpers only. Python tests run in Docker." >&2
    exit 1
fi
if [[ ! -f "${DOCKERFILE_TEST}" ]]; then
    printf '%s\n' "Missing test Dockerfile: ${DOCKERFILE_TEST}" >&2
    exit 1
fi
if [[ ! -f "${BACKEND}/uv.lock" || ! -f "${BACKEND}/pyproject.toml" ]]; then
    printf '%s\n' "Missing locked Python project files under ${BACKEND}." >&2
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
        'no such object:|no such container:|no such network:|no such image:|error: no such (object|container|network|image)|network[[:space:]]+[^[:space:]]+[[:space:]]+not found' \
        <<<"${msg}"
}

# Probe a Docker container. Return: 0=exists, 1=absent, 2=inspect/daemon error.
# Does not change the caller's errexit mode.
probe_docker_container() {
    local name="$1"
    local err rc=0
    DOCKER_PROBE_ERROR=""
    err="$(docker container inspect "${name}" 2>&1 >/dev/null)" || rc=$?
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
# Does not change the caller's errexit mode.
probe_docker_network() {
    local name="$1"
    local err rc=0
    DOCKER_PROBE_ERROR=""
    err="$(docker network inspect "${name}" 2>&1 >/dev/null)" || rc=$?
    if [[ "${rc}" -eq 0 ]]; then
        return 0
    fi
    DOCKER_PROBE_ERROR="${err}"
    if is_docker_not_found_error "${err}"; then
        return 1
    fi
    return 2
}

# Probe a Docker image. Return: 0=exists, 1=absent, 2=inspect/daemon error.
# Does not change the caller's errexit mode.
probe_docker_image() {
    local name="$1"
    local err rc=0
    DOCKER_PROBE_ERROR=""
    err="$(docker image inspect "${name}" 2>&1 >/dev/null)" || rc=$?
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

run_probe_image() {
    if probe_docker_image "$1"; then
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
TEST_IMAGE="sjv-isolated-schema-py:${RUN_ID}"
OWNED_TEST_IMAGE="${TEST_IMAGE}"

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

# Ownership helpers must not toggle the caller's errexit mode (set -e / set +e).
container_owned_by_this_run() {
    local name="$1"
    local label_test label_run
    if ! label_test="$(docker inspect -f "{{index .Config.Labels \"${LABEL_TEST_KEY}\"}}" "${name}" 2>/dev/null)"; then
        return 1
    fi
    if ! label_run="$(docker inspect -f "{{index .Config.Labels \"${LABEL_RUN_KEY}\"}}" "${name}" 2>/dev/null)"; then
        return 1
    fi
    [[ "${label_test}" == "${LABEL_TEST_VALUE}" && "${label_run}" == "${RUN_ID}" ]]
}

network_owned_by_this_run() {
    local name="$1"
    local label_test label_run
    if ! label_test="$(docker network inspect -f "{{index .Labels \"${LABEL_TEST_KEY}\"}}" "${name}" 2>/dev/null)"; then
        return 1
    fi
    if ! label_run="$(docker network inspect -f "{{index .Labels \"${LABEL_RUN_KEY}\"}}" "${name}" 2>/dev/null)"; then
        return 1
    fi
    [[ "${label_test}" == "${LABEL_TEST_VALUE}" && "${label_run}" == "${RUN_ID}" ]]
}

image_owned_by_this_run() {
    local name="$1"
    local label_test label_run
    if ! label_test="$(docker image inspect -f "{{index .Config.Labels \"${LABEL_TEST_KEY}\"}}" "${name}" 2>/dev/null)"; then
        return 1
    fi
    if ! label_run="$(docker image inspect -f "{{index .Config.Labels \"${LABEL_RUN_KEY}\"}}" "${name}" 2>/dev/null)"; then
        return 1
    fi
    [[ "${label_test}" == "${LABEL_TEST_VALUE}" && "${label_run}" == "${RUN_ID}" ]]
}

# Assert a container is attached to exactly one Docker network and that it is expected.
# Returns 1 on failure (does not exit) so callers can clean up ephemeral containers.
# Does not change the caller's errexit mode.
assert_container_only_on_network() {
    local name="$1"
    local expected_net="$2"
    local count net
    if ! require_local_docker; then
        return 1
    fi
    if ! container_owned_by_this_run "${name}"; then
        printf '%s\n' "Refusing network check: container '${name}' is not owned by this run." >&2
        return 1
    fi
    if ! count="$(docker inspect -f '{{len .NetworkSettings.Networks}}' "${name}" 2>/dev/null)"; then
        printf '%s\n' "Failed to inspect network count for container '${name}'." >&2
        return 1
    fi
    if ! net="$(docker inspect -f '{{range $k, $_ := .NetworkSettings.Networks}}{{$k}}{{end}}' "${name}" 2>/dev/null)"; then
        printf '%s\n' "Failed to inspect network name for container '${name}'." >&2
        return 1
    fi
    if [[ "${count}" != "1" ]]; then
        printf '%s\n' "Container '${name}' must be on exactly one network (found ${count:-unknown})." >&2
        return 1
    fi
    if [[ "${net}" != "${expected_net}" ]]; then
        printf '%s\n' "Container '${name}' is on '${net}', expected '${expected_net}'." >&2
        return 1
    fi
    return 0
}

# Restore mode 600 then delete secret/url/env files under the owned TEST_ROOT only.
remove_secret_files_from_test_root() {
    local f
    local old_nullglob
    local rc=0
    if [[ -z "${TEST_ROOT}" || -z "${OWNED_TEST_ROOT}" ]]; then
        return 0
    fi
    if [[ "${TEST_ROOT}" != "${OWNED_TEST_ROOT}" ]]; then
        printf '%s\n' "Refusing secret cleanup: TEST_ROOT does not match OWNED_TEST_ROOT." >&2
        CLEANUP_FAILED=1
        return 1
    fi
    case "${OWNED_TEST_ROOT}" in
        */sjv-alembic-itest.*)
            ;;
        *)
            printf '%s\n' "Refusing secret cleanup: unexpected TEST_ROOT='${OWNED_TEST_ROOT}'." >&2
            CLEANUP_FAILED=1
            return 1
            ;;
    esac
    if [[ ! -d "${OWNED_TEST_ROOT}" ]]; then
        return 0
    fi
    if [[ -L "${OWNED_TEST_ROOT}" ]]; then
        printf '%s\n' "Refusing secret cleanup: TEST_ROOT is a symbolic link." >&2
        CLEANUP_FAILED=1
        return 1
    fi

    old_nullglob="$(shopt -p nullglob)"
    shopt -s nullglob
    for f in "${OWNED_TEST_ROOT}"/secret-* "${OWNED_TEST_ROOT}"/url-*; do
        if [[ -L "${f}" ]]; then
            printf '%s\n' "Refusing to chmod symlink '${f}'." >&2
            CLEANUP_FAILED=1
            rc=1
            continue
        fi
        if [[ ! -f "${f}" ]]; then
            continue
        fi
        if ! chmod 600 -- "${f}"; then
            printf '%s\n' "Failed to restore mode 600 on '${f}'." >&2
            CLEANUP_FAILED=1
            rc=1
        fi
    done
    for f in "${OWNED_TEST_ROOT}"/secret-* "${OWNED_TEST_ROOT}"/url-* "${OWNED_TEST_ROOT}"/env.file; do
        if [[ -L "${f}" ]]; then
            printf '%s\n' "Refusing to delete symlink '${f}'." >&2
            CLEANUP_FAILED=1
            rc=1
            continue
        fi
        if [[ ! -e "${f}" ]]; then
            continue
        fi
        if ! rm -f -- "${f}"; then
            printf '%s\n' "Failed to remove '${f}'." >&2
            CLEANUP_FAILED=1
            rc=1
        fi
    done
    eval "${old_nullglob}"
    return "${rc}"
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
    rc=0
    err="$(docker rm -f "${name}" 2>&1 >/dev/null)" || rc=$?
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
    rc=0
    err="$(docker network rm "${name}" 2>&1 >/dev/null)" || rc=$?
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

# Remove only the image ID created by this run. Requires matching Id and ownership labels.
# Does not change the caller's errexit mode.
remove_owned_image() {
    local image_id="$1"
    local tag_name="${2-}"
    local rc=0 err current_id tag_id
    if [[ -z "${image_id}" ]]; then
        return 0
    fi
    if ! require_local_docker; then
        printf '%s\n' "Refusing to remove image '${image_id}': Docker daemon check failed before inspect/delete." >&2
        CLEANUP_FAILED=1
        return 1
    fi
    run_probe_image "${image_id}"
    if [[ "${PROBE_RC}" -eq 1 ]]; then
        return 0
    fi
    if [[ "${PROBE_RC}" -eq 2 ]]; then
        printf '%s\n' "Cannot reliably verify image '${image_id}' before delete: ${DOCKER_PROBE_ERROR}" >&2
        CLEANUP_FAILED=1
        return 1
    fi
    rc=0
    current_id="$(docker image inspect -f '{{.Id}}' "${image_id}" 2>/dev/null)" || rc=$?
    if [[ "${rc}" -ne 0 || -z "${current_id}" ]]; then
        printf '%s\n' "Skipping image removal: cannot read Id for '${image_id}'." >&2
        CLEANUP_FAILED=1
        return 1
    fi
    if [[ "${current_id}" != "${image_id}" ]]; then
        printf '%s\n' "Skipping image removal: Id mismatch (expected ${image_id}, found ${current_id})." >&2
        CLEANUP_FAILED=1
        return 1
    fi
    if ! image_owned_by_this_run "${image_id}"; then
        printf '%s\n' "Skipping image '${image_id}' removal: ownership labels do not match this run." >&2
        CLEANUP_FAILED=1
        return 1
    fi
    if [[ -n "${tag_name}" ]]; then
        run_probe_image "${tag_name}"
        if [[ "${PROBE_RC}" -eq 0 ]]; then
            rc=0
            tag_id="$(docker image inspect -f '{{.Id}}' "${tag_name}" 2>/dev/null)" || rc=$?
            if [[ "${rc}" -ne 0 || "${tag_id}" != "${image_id}" ]]; then
                printf '%s\n' "Skipping image removal: tag '${tag_name}' no longer points at owned Id." >&2
                CLEANUP_FAILED=1
                return 1
            fi
        elif [[ "${PROBE_RC}" -eq 2 ]]; then
            printf '%s\n' "Cannot reliably verify tag '${tag_name}' before delete: ${DOCKER_PROBE_ERROR}" >&2
            CLEANUP_FAILED=1
            return 1
        fi
    fi
    if ! require_local_docker; then
        printf '%s\n' "Refusing to remove image '${image_id}': Docker daemon check failed before delete." >&2
        CLEANUP_FAILED=1
        return 1
    fi
    rc=0
    err="$(docker rmi "${image_id}" 2>&1 >/dev/null)" || rc=$?
    if [[ "${rc}" -eq 0 ]]; then
        return 0
    fi
    if is_docker_not_found_error "${err}"; then
        return 0
    fi
    printf '%s\n' "Failed to remove owned image '${image_id}': ${err}" >&2
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

    # Ephemeral Python test container (named, may still be running after interrupt).
    # Clear the name only after a successful owned remove; keep it on failure
    # so the object identity is not lost after a daemon/rm error.
    if [[ -n "${PY_RUN_CONTAINER}" ]]; then
        if remove_owned_container "${PY_RUN_CONTAINER}"; then
            PY_RUN_CONTAINER=""
        else
            CLEANUP_FAILED=1
        fi
    fi

    if ! require_local_docker; then
        printf '%s\n' "Skipping Docker object cleanup: daemon check failed before inspect." >&2
        CLEANUP_FAILED=1
        skip_network_removal=1
        # Keep CONTAINER / NETWORK / image Ids for diagnosis; do not clear them.
    elif [[ -n "${CONTAINER}" ]]; then
        run_probe_container "${CONTAINER}"
        if [[ "${PROBE_RC}" -eq 2 ]]; then
            printf '%s\n' "Cannot reliably verify container '${CONTAINER}' during cleanup: ${DOCKER_PROBE_ERROR}" >&2
            CLEANUP_FAILED=1
            skip_network_removal=1
            # Keep CONTAINER set; ownership/delete was not confirmed.
        elif [[ "${PROBE_RC}" -eq 0 ]]; then
            if container_owned_by_this_run "${CONTAINER}"; then
                docker logs "${CONTAINER}" > "${TEST_ROOT}/postgres.log" 2>&1 || true
            fi
            # If container delete is refused, do not touch the network on a
            # potentially different Docker endpoint. Keep CONTAINER on failure.
            if remove_owned_container "${CONTAINER}"; then
                CONTAINER=""
            else
                skip_network_removal=1
                CLEANUP_FAILED=1
            fi
        fi
    fi

    if [[ "${skip_network_removal}" -eq 1 ]]; then
        if [[ -n "${NETWORK}" ]]; then
            printf '%s\n' "Skipping network '${NETWORK}' removal after container cleanup failure or unreliable container state." >&2
            CLEANUP_FAILED=1
            # Keep NETWORK set; it was not removed.
        fi
    elif [[ -n "${NETWORK}" ]]; then
        if remove_owned_network "${NETWORK}"; then
            NETWORK=""
        else
            CLEANUP_FAILED=1
        fi
    fi

    # Image cleanup: only the Id recorded after a successful owned build.
    # Clear tracking vars only after a successful owned remove.
    if [[ "${BUILT_TEST_IMAGE}" -eq 1 ]]; then
        if [[ -n "${OWNED_TEST_IMAGE_ID}" && -n "${OWNED_TEST_IMAGE}" && "${OWNED_TEST_IMAGE}" == "${TEST_IMAGE}" ]]; then
            if remove_owned_image "${OWNED_TEST_IMAGE_ID}" "${TEST_IMAGE}"; then
                OWNED_TEST_IMAGE_ID=""
                OWNED_TEST_IMAGE=""
                BUILT_TEST_IMAGE=0
            else
                CLEANUP_FAILED=1
            fi
        else
            printf '%s\n' "Skipping image removal: ownership tracking is inconsistent (BUILT=${BUILT_TEST_IMAGE}, id='${OWNED_TEST_IMAGE_ID}', tag='${TEST_IMAGE}')." >&2
            CLEANUP_FAILED=1
        fi
    elif [[ -n "${OWNED_TEST_IMAGE_ID}" ]]; then
        printf '%s\n' "Skipping image removal: image Id is set but BUILT_TEST_IMAGE is not." >&2
        CLEANUP_FAILED=1
    fi

    if [[ "${status}" -ne 0 && -n "${TEST_ROOT}" && -f "${TEST_ROOT}/postgres.log" ]]; then
        show_log "${TEST_ROOT}/postgres.log"
    fi
    if ! remove_secret_files_from_test_root; then
        :
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
    for secret in "${TEST_ROOT}"/secret-* "${TEST_ROOT}"/url-*; do
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

# --internal: containers on this network can reach each other only.
# No egress to the host gateway, the internet, or production Docker networks.
docker network create \
    --internal \
    --label "${LABEL_TEST_KEY}=${LABEL_TEST_VALUE}" \
    --label "${LABEL_RUN_KEY}=${RUN_ID}" \
    "${NETWORK}" >/dev/null

# Build the disposable Python test image (deps from uv.lock; runtime has no uv/pip).
run_probe_image "${TEST_IMAGE}"
if [[ "${PROBE_RC}" -eq 0 ]]; then
    printf '%s\n' "Test image ${TEST_IMAGE} already exists." >&2
    exit 1
fi
if [[ "${PROBE_RC}" -eq 2 ]]; then
    printf '%s\n' "Failed to inspect test image '${TEST_IMAGE}' before build: ${DOCKER_PROBE_ERROR}" >&2
    exit 1
fi
run_logged "${TEST_ROOT}/build-test-image.log" \
    docker build \
        --label "${LABEL_TEST_KEY}=${LABEL_TEST_VALUE}" \
        --label "${LABEL_RUN_KEY}=${RUN_ID}" \
        -f "${DOCKERFILE_TEST}" \
        -t "${TEST_IMAGE}" \
        "${BACKEND}"
built_id=""
set +e
built_id="$(docker image inspect -f '{{.Id}}' "${TEST_IMAGE}" 2>/dev/null)"
built_id_rc=$?
set -e
if [[ "${built_id_rc}" -ne 0 || -z "${built_id}" ]]; then
    printf '%s\n' "Built test image exists but its Id could not be read." >&2
    CLEANUP_FAILED=1
    exit 1
fi
if ! image_owned_by_this_run "${TEST_IMAGE}"; then
    printf '%s\n' "Built test image is missing ownership labels; leaving image ${built_id} in place." >&2
    # Without labels we must not delete: Id alone is not sufficient ownership proof here.
    CLEANUP_FAILED=1
    OWNED_TEST_IMAGE=""
    OWNED_TEST_IMAGE_ID=""
    BUILT_TEST_IMAGE=0
    TEST_IMAGE=""
    exit 1
fi
if ! image_owned_by_this_run "${built_id}"; then
    printf '%s\n' "Built test image Id lacks ownership labels; leaving image ${built_id} in place." >&2
    CLEANUP_FAILED=1
    OWNED_TEST_IMAGE=""
    OWNED_TEST_IMAGE_ID=""
    BUILT_TEST_IMAGE=0
    TEST_IMAGE=""
    exit 1
fi
OWNED_TEST_IMAGE_ID="${built_id}"
BUILT_TEST_IMAGE=1

run_logged "${TEST_ROOT}/pull.log" docker pull "${IMAGE}"

docker run -d \
    --name "${CONTAINER}" \
    --label "${LABEL_TEST_KEY}=${LABEL_TEST_VALUE}" \
    --label "${LABEL_RUN_KEY}=${RUN_ID}" \
    --network "${NETWORK}" \
    --env-file "${TEST_ROOT}/env.file" \
    --tmpfs /var/lib/postgresql:mode=1777 \
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
assert_container_only_on_network "${CONTAINER}" "${NETWORK}"

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

write_url() {
    local database="$1"
    local target="$2"
    # Connect via the isolated Docker network hostname, not a host-published port.
    DB_NAME="${database}" PGHOST="${CONTAINER}" SECRET_FILE="${TEST_ROOT}/secret-bootstrap" URL_FILE="${target}" \
        python3 - <<'PY'
import errno
import os
import stat
import sys
from pathlib import Path
from urllib.parse import quote

path = os.environ["URL_FILE"]
password = Path(os.environ["SECRET_FILE"]).read_text(encoding="utf-8")
url = (
    "postgresql+psycopg://sjv_bootstrap:"
    + quote(password)
    + "@"
    + os.environ["PGHOST"]
    + ":5432/"
    + os.environ["DB_NAME"]
)
payload = url.encode("utf-8")

try:
    info = os.lstat(path)
except FileNotFoundError:
    info = None
except OSError as exc:
    sys.stderr.write("Failed to stat URL file %s: %s\n" % (path, exc))
    sys.exit(1)
else:
    if stat.S_ISLNK(info.st_mode):
        sys.stderr.write("Refusing URL file that is a symbolic link: %s\n" % path)
        sys.exit(1)
    if not stat.S_ISREG(info.st_mode):
        sys.stderr.write("Refusing URL path that is not a regular file: %s\n" % path)
        sys.exit(1)
    try:
        os.unlink(path)
    except OSError as exc:
        sys.stderr.write("Failed to replace URL file %s: %s\n" % (path, exc))
        sys.exit(1)

flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW
if hasattr(os, "O_CLOEXEC"):
    flags |= os.O_CLOEXEC

fd = None
try:
    fd = os.open(path, flags, 0o600)
    os.fchmod(fd, 0o600)
    offset = 0
    while offset < len(payload):
        written = os.write(fd, payload[offset:])
        if written <= 0:
            raise OSError("short write while creating URL file")
        offset += written
except OSError as exc:
    if fd is not None:
        try:
            os.close(fd)
        except OSError:
            pass
        fd = None
    try:
        if not os.path.islink(path):
            os.unlink(path)
    except FileNotFoundError:
        pass
    except OSError:
        pass
    if exc.errno == errno.EEXIST:
        sys.stderr.write("URL file already exists unexpectedly: %s\n" % path)
    else:
        sys.stderr.write("Failed to write URL file %s: %s\n" % (path, exc))
    sys.exit(1)
else:
    os.close(fd)
PY
}

# Run a command inside the owned test image on the isolated --internal network.
# Optional: --url-file PATH mounts the URL file and sets SJV_DATABASE_URL inside
# the container (avoids putting the password on the docker CLI / Config.Env).
run_in_test_image() {
    local logfile="$1"
    shift
    local url_file=""
    local -a mount_args=()
    local -a run_cmd=()
    local status=0
    local run_name=""
    local wait_out=""
    local wait_rc=0
    local logs_rc=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --url-file)
                if [[ $# -lt 2 ]]; then
                    printf '%s\n' "run_in_test_image: --url-file requires a path." >&2
                    exit 1
                fi
                url_file="$2"
                shift 2
                ;;
            --)
                shift
                break
                ;;
            -*)
                printf '%s\n' "run_in_test_image: unknown option $1" >&2
                exit 1
                ;;
            *)
                break
                ;;
        esac
    done
    if [[ $# -lt 1 ]]; then
        printf '%s\n' "run_in_test_image: missing command." >&2
        exit 1
    fi
    if ! require_local_docker; then
        exit 1
    fi
    if [[ "${BUILT_TEST_IMAGE}" -ne 1 || -z "${OWNED_TEST_IMAGE_ID}" ]]; then
        printf '%s\n' "Refusing to run tests: owned test image Id was not recorded." >&2
        exit 1
    fi
    if [[ -z "${TEST_IMAGE}" ]] || ! image_owned_by_this_run "${TEST_IMAGE}"; then
        printf '%s\n' "Refusing to run tests: owned test image is missing." >&2
        exit 1
    fi
    if [[ "$(docker image inspect -f '{{.Id}}' "${TEST_IMAGE}")" != "${OWNED_TEST_IMAGE_ID}" ]]; then
        printf '%s\n' "Refusing to run tests: test image tag no longer matches owned Id." >&2
        exit 1
    fi
    # PostgreSQL must remain solely on the isolated test network.
    if ! assert_container_only_on_network "${CONTAINER}" "${NETWORK}"; then
        exit 1
    fi
    if [[ -n "${url_file}" ]]; then
        if [[ ! -f "${url_file}" || -L "${url_file}" ]]; then
            printf '%s\n' "run_in_test_image: URL file missing or is a symlink." >&2
            exit 1
        fi
        # Parent TEST_ROOT is mode 700 (owner-only). Mode 644 lets uid 10001
        # (sjvtest) read the bind-mounted inode without putting the secret in -e.
        chmod 644 "${url_file}"
        mount_args+=(-v "${url_file}:/run/sjv/database-url:ro")
        # Load SJV_DATABASE_URL inside the container, then exec the real command.
        run_cmd=(
            python -c
            'import os, sys
from pathlib import Path
os.environ["SJV_DATABASE_URL"] = Path("/run/sjv/database-url").read_text(encoding="utf-8").rstrip("\n")
os.execvp(sys.argv[1], sys.argv[1:])'
            "$@"
        )
    else
        run_cmd=("$@")
    fi

    # Named container (no --rm) so network membership can be verified while it exists.
    run_name="sjv-itest-py-${RUN_ID}-$(python3 -c 'import uuid; print(uuid.uuid4().hex[:16])')"
    # Register before docker run so EXIT cleanup can reclaim even if the client
    # returns an error after the daemon created the container.
    PY_RUN_CONTAINER="${run_name}"

    # Keep set +e through return so a failing command status reaches the caller.
    # Helpers below must not toggle errexit (would skip chmod 600 restore).
    set +e
    docker run -d \
        --name "${run_name}" \
        --network "${NETWORK}" \
        --label "${LABEL_TEST_KEY}=${LABEL_TEST_VALUE}" \
        --label "${LABEL_RUN_KEY}=${RUN_ID}" \
        -e PYTHONDONTWRITEBYTECODE=1 \
        -e PYTHONPATH=/app \
        "${mount_args[@]}" \
        "${TEST_IMAGE}" \
        "${run_cmd[@]}" >/dev/null
    status=$?
    if [[ "${status}" -ne 0 ]]; then
        printf '%s\n' "docker run failed for test container '${run_name}' (exit ${status})." >&2
        # Keep PY_RUN_CONTAINER for EXIT unless an immediate owned remove succeeds.
        # remove_owned_container probes existence, checks labels, never deletes foreign.
        if remove_owned_container "${run_name}"; then
            PY_RUN_CONTAINER=""
        fi
    else
        if ! assert_container_only_on_network "${run_name}" "${NETWORK}"; then
            status=1
            docker logs "${run_name}" > "${logfile}" 2>&1
            logs_rc=$?
            if [[ "${logs_rc}" -ne 0 ]]; then
                printf '%s\n' "Failed to collect docker logs for '${run_name}' (exit ${logs_rc})." >&2
                status=1
            fi
        else
            wait_out="$(docker wait "${run_name}" 2>/dev/null)"
            wait_rc=$?
            if [[ "${wait_rc}" -ne 0 || ! "${wait_out}" =~ ^[0-9]+$ ]]; then
                status=1
            else
                status="${wait_out}"
            fi
            docker logs "${run_name}" > "${logfile}" 2>&1
            logs_rc=$?
            if [[ "${logs_rc}" -ne 0 ]]; then
                printf '%s\n' "Failed to collect docker logs for '${run_name}' (exit ${logs_rc})." >&2
                if [[ "${status}" -eq 0 ]]; then
                    status=1
                fi
            fi
        fi
        # Always attempt owned remove after wait/logs (including logs failure).
        if remove_owned_container "${run_name}"; then
            PY_RUN_CONTAINER=""
        else
            # Leave PY_RUN_CONTAINER set for EXIT cleanup retry.
            if [[ "${status}" -eq 0 ]]; then
                status=1
            fi
        fi
    fi
    # Restore URL permissions even when docker run/wait/logs/remove failed.
    if [[ -n "${url_file}" && -e "${url_file}" && ! -L "${url_file}" ]]; then
        if ! chmod 600 "${url_file}"; then
            printf '%s\n' "Failed to restore mode 600 on URL file after docker run." >&2
            CLEANUP_FAILED=1
            if [[ "${status}" -eq 0 ]]; then
                status=1
            fi
        fi
    fi
    return "${status}"
}

run_recovery_unit_tests() {
    # psycopg comes from the test image (/opt/sjv-venv); never use host python3/uv here.
    local logfile="${TEST_ROOT}/recovery-unit.log"
    set +e
    run_in_test_image "${logfile}" python tests/test_recovery.py
    local status=$?
    set -e
    show_log "${logfile}"
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
    run_in_test_image "${upgrade_log}" \
        --url-file "${urlfile}" \
        -- \
        alembic -c alembic.ini upgrade head
    local upgrade_status=$?
    set -e
    if [[ "${upgrade_status}" -ne 0 ]]; then
        show_log "${upgrade_log}"
        exit "${upgrade_status}"
    fi
    set +e
    run_in_test_image "${check_log}" \
        --url-file "${urlfile}" \
        -- \
        alembic -c alembic.ini check
    local check_status=$?
    set -e
    if [[ "${check_status}" -ne 0 ]]; then
        show_log "${check_log}"
        exit "${check_status}"
    fi
    local downgrade_log="${TEST_ROOT}/downgrade-${database}.log"
    set +e
    run_in_test_image "${downgrade_log}" \
        --url-file "${urlfile}" \
        -- \
        alembic -c alembic.ini downgrade -1
    local downgrade_status=$?
    set -e
    if [[ "${downgrade_status}" -eq 0 ]] || ! grep -q 'forward-only' "${downgrade_log}"; then
        printf '%s\n' "Downgrade was not refused as forward-only." >&2
        show_log "${downgrade_log}"
        exit 1
    fi
    set +e
    run_in_test_image "${TEST_ROOT}/schema-${database}.log" \
        --url-file "${urlfile}" \
        -- \
        python tests/schema_tests.py
    local schema_status=$?
    set -e
    show_log "${TEST_ROOT}/schema-${database}.log"
    if [[ "${schema_status}" -ne 0 ]]; then
        exit "${schema_status}"
    fi
    set +e
    run_in_test_image "${TEST_ROOT}/accept-${database}.log" \
        --url-file "${urlfile}" \
        -- \
        python tests/ingest_accept_tests.py
    local accept_status=$?
    set -e
    show_log "${TEST_ROOT}/accept-${database}.log"
    if [[ "${accept_status}" -ne 0 ]]; then
        exit "${accept_status}"
    fi
    set +e
    run_in_test_image "${TEST_ROOT}/retention-${database}.log" \
        --url-file "${urlfile}" \
        -- \
        python tests/retention_tests.py
    local retention_status=$?
    set -e
    show_log "${TEST_ROOT}/retention-${database}.log"
    if [[ "${retention_status}" -ne 0 ]]; then
        exit "${retention_status}"
    fi
    set +e
    run_in_test_image "${TEST_ROOT}/recovery-${database}.log" \
        --url-file "${urlfile}" \
        -- \
        python tests/recovery_tests.py
    local recovery_status=$?
    set -e
    show_log "${TEST_ROOT}/recovery-${database}.log"
    if [[ "${recovery_status}" -ne 0 ]]; then
        exit "${recovery_status}"
    fi
    # Mode should already be 600 after each docker run; enforce before delete.
    if [[ -e "${urlfile}" && ! -L "${urlfile}" ]]; then
        chmod 600 "${urlfile}"
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
