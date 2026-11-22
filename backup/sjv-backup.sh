#!/bin/bash
# Scheduler and Restic client for the permanent sjv-backup container.
# Runs daily and wal backups. Never forget, prune, or delete snapshots.
set -Eeuo pipefail

readonly BACKUP_ROOT="${SJV_BACKUP_ROOT:-/backup}"
readonly LOCK_DIR="${SJV_BACKUP_LOCK_DIR:-/locks}"
readonly STATE_DIR="${SJV_BACKUP_STATE_DIR:-/state}"
readonly HEARTBEAT="${SJV_BACKUP_HEARTBEAT:-/run/sjv-backup/heartbeat}"
readonly PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-/run/secrets/restic-key-password}"
readonly CACERT="${SJV_BACKUP_CACERT:-/certs/rest-server.crt}"
readonly RESTIC_BIN="${SJV_BACKUP_RESTIC:-restic}"
# Success, an empty archive and a Restic error all wait this long.
# SJV_BACKUP_LOCK_WAIT is not read: waiting on repo.lock used to stall
# supervise() for the old 600 second default.
readonly WAL_INTERVAL="${SJV_BACKUP_WAL_SECONDS:-300}"
# Busy restic-job.lock or repo.lock retries sooner, but not in a tight loop.
readonly WAL_RETRY="${SJV_BACKUP_WAL_RETRY_SECONDS:-60}"
readonly TICK_SECONDS="${SJV_BACKUP_TICK_SECONDS:-15}"
readonly DAILY_AT="${SJV_BACKUP_DAILY_AT:-03:15}"
readonly HEALTH_MAX_AGE="${SJV_BACKUP_HEALTH_MAX_AGE:-90}"
readonly HEARTBEAT_INTERVAL="${SJV_BACKUP_HEARTBEAT_SECONDS:-15}"
readonly JOB_LOCK="${LOCK_DIR}/restic-job.lock"
readonly REPO_LOCK="${LOCK_DIR}/repo.lock"

CHILD=0
HEARTBEAT_PID=0

log_msg() {
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

stop_child() {
    local pid="${CHILD}"
    [[ "${pid}" -ne 0 ]] || return 0
    CHILD=0
    # The job has its own process group, so this also stops a sleep it
    # spawned and does not signal the scheduler or the heartbeat group.
    kill -TERM -"${pid}" 2>/dev/null || kill -TERM "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
}

write_heartbeat() {
    mkdir -p "$(dirname "${HEARTBEAT}")"
    date +%s > "${HEARTBEAT}"
}

start_heartbeat() {
    [[ "${HEARTBEAT_PID}" -eq 0 ]] || return 0
    write_heartbeat
    # Monitor mode gives this loop its own process group, so SIGTERM also
    # reaches the sleep inside it and does not leave that sleep behind.
    set -m
    (
        trap 'exit 0' TERM INT
        while true; do
            sleep "${HEARTBEAT_INTERVAL}"
            date +%s > "${HEARTBEAT}" || exit 0
        done
    ) &
    HEARTBEAT_PID=$!
    set +m
}

stop_heartbeat() {
    local pid="${HEARTBEAT_PID}"
    [[ "${pid}" -ne 0 ]] || return 0
    HEARTBEAT_PID=0
    kill -TERM -"${pid}" 2>/dev/null || kill -TERM "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
}

finish() {
    local status=$?
    stop_heartbeat
    exit "${status}"
}

on_signal() {
    log_msg "sjv-backup stopping"
    stop_child
    exit 0
}

write_state() {
    local mode="$1" status="$2" code="$3" path tmp
    path="${STATE_DIR}/sjv-backup-${mode}.json"
    tmp="${path}.tmp"
    mkdir -p "${STATE_DIR}"
    printf '{"mode":"%s","status":"%s","exit_code":%s,"finished_at":"%s"}\n' \
        "${mode}" "${status}" "${code}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${tmp}"
    mv -f "${tmp}" "${path}"
}

write_epoch() {
    local path="$1" value="$2" tmp
    tmp="${path}.tmp"
    mkdir -p "$(dirname "${path}")"
    printf '%s\n' "${value}" > "${tmp}"
    mv -f "${tmp}" "${path}"
}

configured() {
    [[ -n "${RESTIC_REPOSITORY:-}" && -n "${RESTIC_REST_PASSWORD:-}" && -f "${PASSWORD_FILE}" && ! -L "${PASSWORD_FILE}" && -s "${PASSWORD_FILE}" && -f "${CACERT}" && ! -L "${CACERT}" && -s "${CACERT}" ]]
}

# A filled repository is incomplete unless the key file and certificate pass
# the same checks as a backup. An empty repository is handled by the caller.
init_repository_ready() {
    local mode_bits
    configured || return 1
    mode_bits="$(stat -c '%a' "${PASSWORD_FILE}")"
    [[ "${mode_bits}" == 600 || "${mode_bits}" == 400 ]]
}

# True only for the one observed missing-repository diagnosis. A Fatal: prefix
# is accepted. Any other line, including a shorter "does not exist", is not.
repository_probe_is_absent() {
    local errfile="$1" line bare saw=0
    local exact="repository does not exist: unable to open config file: <config/> does not exist"
    [[ -s "${errfile}" && ! -L "${errfile}" ]] || return 1
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line%$'\r'}"
        [[ -n "${line}" ]] || continue
        bare="${line}"
        if [[ "${bare}" == "Fatal: ${exact}" ]]; then
            bare="${exact}"
        fi
        [[ "${bare}" == "${exact}" ]] || return 1
        saw=1
    done < "${errfile}"
    [[ "${saw}" -eq 1 ]]
}

INIT_ERRFILE=""

# shellcheck disable=SC2317,SC2329
init_cleanup() {
    local status=$?
    release_locks
    if [[ -n "${INIT_ERRFILE}" && -f "${INIT_ERRFILE}" && ! -L "${INIT_ERRFILE}" ]]; then
        rm -f -- "${INIT_ERRFILE}"
    fi
    exit "${status}"
}

# shellcheck disable=SC2317,SC2329
init_on_signal() {
    log_msg "init-repository interrupted"
    stop_child
    exit 1
}

init_repository() {
    local rc=0
    if [[ -z "${RESTIC_REPOSITORY:-}" ]]; then
        log_msg "init-repository: remote backup is not configured"
        return 0
    fi
    if ! init_repository_ready; then
        log_msg "init-repository refused: remote backup configuration is incomplete"
        return 1
    fi
    trap init_cleanup EXIT
    trap init_on_signal INT TERM
    mkdir -p "${LOCK_DIR}"
    exec 8>"${REPO_LOCK}"
    if ! flock -x -n 8; then
        log_msg "init-repository refused: repository lock was not free"
        return 1
    fi
    INIT_ERRFILE="$(mktemp)"
    prepare_repository
    run_restic --cacert "${CACERT}" cat config >/dev/null 2>"${INIT_ERRFILE}" || rc=$?
    if [[ "${rc}" -eq 0 ]]; then
        log_msg "init-repository: repository already exists"
        return 0
    fi
    if ! repository_probe_is_absent "${INIT_ERRFILE}"; then
        log_msg "init-repository refused: repository probe failed"
        return "${rc}"
    fi
    log_msg "init-repository: repository is absent"
    rc=0
    run_restic --cacert "${CACERT}" init >/dev/null 2>"${INIT_ERRFILE}" || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        log_msg "init-repository refused: repository initialization failed"
        return "${rc}"
    fi
    rc=0
    run_restic --cacert "${CACERT}" cat config >/dev/null 2>"${INIT_ERRFILE}" || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        log_msg "init-repository refused: repository configuration was not readable after initialization"
        return "${rc}"
    fi
    log_msg "init-repository: repository is ready"
    return 0
}

# Restic 0.19.1 ignores RESTIC_REST_PASSWORD when the URL already contains a
# username (restic issue 22035). A username in the URL is removed and exported
# as RESTIC_REST_USERNAME. A URL without one keeps the value already in the
# environment. The password stays in RESTIC_REST_PASSWORD and is not logged.
prepare_repository() {
    local repo="${RESTIC_REPOSITORY}"
    local username="${RESTIC_REST_USERNAME:-}"
    if [[ "${repo}" =~ ^rest:https://([^/:@]+)@([^/:@]+):([0-9]+)/(.*)$ ]]; then
        username="${BASH_REMATCH[1]}"
        repo="rest:https://${BASH_REMATCH[2]}:${BASH_REMATCH[3]}/${BASH_REMATCH[4]}"
    fi
    export RESTIC_REPOSITORY="${repo}"
    export RESTIC_REST_USERNAME="${username}"
    export RESTIC_PASSWORD_FILE="${PASSWORD_FILE}"
    unset RESTIC_PASSWORD
}

# A real WAL segment is a regular file. Temporary pgBackRest files do not count.
wal_archive_ready() {
    local archive="${BACKUP_ROOT}/pgbackrest/archive" file
    [[ -d "${archive}" && ! -L "${archive}" ]] || return 1
    while IFS= read -r -d '' file; do
        [[ -f "${file}" && ! -L "${file}" ]] || continue
        [[ "$(basename -- "${file}")" == *.pgbackrest.tmp ]] && continue
        return 0
    done < <(find "${archive}" -xdev -type f -print0)
    return 1
}

release_locks() {
    exec 9>&- || true
    exec 8>&- || true
    exec 7>&- || true
}

run_restic() {
    local rc=0
    # Own process group so SIGTERM reaches a sleep inside the command.
    # Lock fds stay in this shell. A child that inherited them would keep
    # restic-job.lock and repo.lock after this process had closed them.
    set -m
    (
        exec 7>&- 8>&- 9>&- || true
        exec "${RESTIC_BIN}" "$@"
    ) &
    CHILD=$!
    set +m
    wait "${CHILD}" || rc=$?
    CHILD=0
    return "${rc}"
}

backup_run() {
    local mode="$1" rc=0
    start_heartbeat
    case "${mode}" in
        daily|wal) ;;
        *)
            log_msg "refusing unknown backup mode"
            return 2
            ;;
    esac
    if ! configured; then
        log_msg "${mode} not started: remote backup is not configured"
        write_state "${mode}" "not-configured" 0
        return 0
    fi
    local mode_bits
    mode_bits="$(stat -c '%a' "${PASSWORD_FILE}")"
    if [[ "${mode_bits}" != 600 && "${mode_bits}" != 400 ]]; then
        log_msg "${mode} refused: repository key file mode is not 600"
        write_state "${mode}" "failed" 1
        return 1
    fi
    if [[ "${mode}" == wal ]] && ! wal_archive_ready; then
        log_msg "wal skipped: archive has no files"
        write_state "${mode}" "skipped-empty" 0
        return 0
    fi
    mkdir -p "${LOCK_DIR}"
    exec 9>"${JOB_LOCK}"
    if ! flock -n 9; then
        log_msg "${mode} skipped: another backup job holds the lock"
        write_state "${mode}" "skipped-locked" 75
        release_locks
        return 75
    fi
    if [[ "${mode}" == daily ]]; then
        # backup.lock is taken before repo.lock. Waiting would hold the
        # scheduler and delay the WAL job past the recovery-point target.
        exec 7>"${LOCK_DIR}/backup.lock"
        if ! flock -s -n 7; then
            log_msg "${mode} skipped: local backup lock was not free"
            write_state "${mode}" "skipped-backup-lock" 75
            release_locks
            return 75
        fi
    fi
    # wal does not take backup.lock, so a local PostgreSQL backup can continue.
    # repo.lock is shared and non-blocking for both jobs. A timed wait would
    # keep restic-job.lock and stall supervise(). Expire and wal still cannot
    # overlap: a busy lock is skipped and released immediately.
    exec 8>"${REPO_LOCK}"
    if ! flock -s -n 8; then
        log_msg "${mode} skipped: repository lock was not free"
        write_state "${mode}" "skipped-repo-lock" 75
        release_locks
        return 75
    fi
    prepare_repository
    # --cacert is a parent flag in Restic 0.19.1, so it precedes the subcommand.
    local -a sources=(--exclude '*.pgbackrest.tmp' --tag "${mode}" --host sjv)
    if [[ "${mode}" == daily ]]; then
        sources+=("${BACKUP_ROOT}/pgbackrest" "${BACKUP_ROOT}/dumps" "${BACKUP_ROOT}/files")
    else
        sources+=("${BACKUP_ROOT}/pgbackrest/archive")
    fi
    log_msg "${mode} backup starting"
    run_restic --cacert "${CACERT}" backup "${sources[@]}" || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        log_msg "${mode} backup failed"
        write_state "${mode}" "failed" "${rc}"
        release_locks
        return "${rc}"
    fi
    run_restic --cacert "${CACERT}" snapshots --latest 1 --tag "${mode}" >/dev/null || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        log_msg "${mode} snapshot check failed"
        write_state "${mode}" "failed" "${rc}"
        release_locks
        return "${rc}"
    fi
    log_msg "${mode} backup finished"
    write_state "${mode}" "ok" 0
    release_locks
}

daily_due() {
    local now stamp last attempt
    now="$(date +%H:%M)"
    stamp="$(date +%F)"
    [[ "${now}" < "${DAILY_AT}" ]] && return 1
    last="${STATE_DIR}/sjv-backup-daily.date"
    [[ -f "${last}" && "$(<"${last}")" == "${stamp}" ]] && return 1
    attempt="${STATE_DIR}/sjv-backup-daily.attempt"
    if [[ -f "${attempt}" ]]; then
        (( $(date +%s) - $(<"${attempt}") >= 900 )) || return 1
    fi
    return 0
}

mark_daily_done() {
    printf '%s\n' "$(date +%F)" > "${STATE_DIR}/sjv-backup-daily.date"
}

mark_daily_attempt() {
    printf '%s\n' "$(date +%s)" > "${STATE_DIR}/sjv-backup-daily.attempt"
}

interval_or_default() {
    local value="$1" fallback="$2"
    if [[ "${value}" =~ ^[1-9][0-9]*$ ]]; then
        printf '%s\n' "${value}"
    else
        printf '%s\n' "${fallback}"
    fi
}

read_epoch() {
    local path="$1" value=""
    [[ -f "${path}" ]] || return 1
    IFS= read -r value < "${path}" || return 1
    [[ "${value}" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "${value}"
}

wal_status() {
    local path="${STATE_DIR}/sjv-backup-wal.json" line=""
    [[ -f "${path}" ]] || return 1
    IFS= read -r line < "${path}" || return 1
    [[ "${line}" =~ \"status\":\"([a-z0-9-]+)\" ]] || return 1
    printf '%s\n' "${BASH_REMATCH[1]}"
}

# Busy locks retry on the short interval. Every other result, including a
# Restic failure, waits the normal interval. Failure stays status "failed".
wal_delay_seconds() {
    local status="$1" retry interval
    retry="$(interval_or_default "${WAL_RETRY}" 60)"
    interval="$(interval_or_default "${WAL_INTERVAL}" 300)"
    case "${status}" in
        skipped-locked|skipped-repo-lock)
            printf '%s\n' "${retry}"
            ;;
        *)
            printf '%s\n' "${interval}"
            ;;
    esac
}

wal_due() {
    local now next last interval
    now="$(date +%s)"
    if next="$(read_epoch "${STATE_DIR}/sjv-backup-wal.next")"; then
        if (( now >= next )); then
            return 0
        fi
        return 1
    fi
    # A restart that only has the last attempt must not run again immediately.
    if last="$(read_epoch "${STATE_DIR}/sjv-backup-wal.epoch")"; then
        interval="$(interval_or_default "${WAL_INTERVAL}" 300)"
        if (( now - last >= interval )); then
            return 0
        fi
        return 1
    fi
    return 0
}

mark_wal() {
    local now status delay next
    now="$(date +%s)"
    status="$(wal_status || true)"
    delay="$(wal_delay_seconds "${status}")"
    next="$(( now + delay ))"
    # The next-attempt file is written first. If the process stops before the
    # attempt stamp, a restart still waits instead of repeating at once.
    write_epoch "${STATE_DIR}/sjv-backup-wal.next" "${next}"
    write_epoch "${STATE_DIR}/sjv-backup-wal.epoch" "${now}"
}

supervise() {
    trap on_signal TERM INT
    trap finish EXIT
    mkdir -p "${STATE_DIR}" "${LOCK_DIR}"
    start_heartbeat
    log_msg "sjv-backup scheduler started"
    while true; do
        write_heartbeat
        if ! configured; then
            log_msg "remote backup is not configured; scheduler is idle"
            sleep 30
            continue
        fi
        if daily_due; then
            if backup_run daily; then
                mark_daily_done
            else
                mark_daily_attempt
            fi
        fi
        if wal_due; then
            backup_run wal || true
            mark_wal
        fi
        sleep "${TICK_SECONDS}"
    done
}

health() {
    [[ -f "${HEARTBEAT}" ]] || exit 1
    local now stamp
    now="$(date +%s)"
    stamp="$(<"${HEARTBEAT}")"
    [[ "${stamp}" =~ ^[0-9]+$ ]] || exit 1
    [[ "${HEALTH_MAX_AGE}" =~ ^[0-9]+$ ]] || exit 1
    (( now - stamp < HEALTH_MAX_AGE ))
}

case "${1:-}" in
    supervise) supervise ;;
    run)
        trap on_signal TERM INT
        trap finish EXIT
        backup_run "${2:-}"
        ;;
    health) health ;;
    init-repository) init_repository ;;
    *)
        log_msg "usage: sjv-backup supervise | run daily|wal | health | init-repository"
        exit 2
        ;;
esac
