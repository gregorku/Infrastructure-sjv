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
readonly WAL_INTERVAL="${SJV_BACKUP_WAL_SECONDS:-300}"
readonly TICK_SECONDS="${SJV_BACKUP_TICK_SECONDS:-15}"
readonly DAILY_AT="${SJV_BACKUP_DAILY_AT:-03:15}"
readonly LOCK_WAIT="${SJV_BACKUP_LOCK_WAIT:-600}"
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
    if [[ "${CHILD}" -ne 0 ]]; then
        kill -TERM "${CHILD}" 2>/dev/null || true
        wait "${CHILD}" 2>/dev/null || true
        CHILD=0
    fi
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

configured() {
    [[ -n "${RESTIC_REPOSITORY:-}" && -n "${RESTIC_REST_PASSWORD:-}" && -f "${PASSWORD_FILE}" && ! -L "${PASSWORD_FILE}" && -s "${PASSWORD_FILE}" && -f "${CACERT}" && ! -L "${CACERT}" ]]
}

# Restic 0.19.1 ignores RESTIC_REST_PASSWORD when the URL already contains a
# username (restic issue 22035). The project URL keeps the username. This
# process strips it and sets RESTIC_REST_USERNAME. The password is not logged.
prepare_repository() {
    local repo="${RESTIC_REPOSITORY}"
    RESTIC_REST_USERNAME=""
    if [[ "${repo}" =~ ^rest:https://([^/:@]+)@([^/:@]+):([0-9]+)/(.*)$ ]]; then
        RESTIC_REST_USERNAME="${BASH_REMATCH[1]}"
        repo="rest:https://${BASH_REMATCH[2]}:${BASH_REMATCH[3]}/${BASH_REMATCH[4]}"
    fi
    export RESTIC_REPOSITORY="${repo}"
    export RESTIC_REST_USERNAME
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
    "${RESTIC_BIN}" "$@" &
    CHILD=$!
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
        # Shared local locks are non-blocking. Waiting here would hold the
        # scheduler and delay the WAL job past the recovery-point target.
        exec 7>"${LOCK_DIR}/backup.lock"
        if ! flock -s -n 7; then
            log_msg "${mode} skipped: local backup lock was not free"
            write_state "${mode}" "skipped-backup-lock" 75
            release_locks
            return 75
        fi
        exec 8>"${REPO_LOCK}"
        if ! flock -s -n 8; then
            log_msg "${mode} skipped: repository lock was not free"
            write_state "${mode}" "skipped-repo-lock" 75
            release_locks
            return 75
        fi
    else
        # wal does not take backup.lock, so it can run during a local backup.
        # It still waits for repo.lock so it does not snapshot during expire.
        exec 8>"${REPO_LOCK}"
        if ! flock -s -w "${LOCK_WAIT}" 8; then
            log_msg "${mode} skipped: repository lock was not free"
            write_state "${mode}" "skipped-repo-lock" 75
            release_locks
            return 75
        fi
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

wal_due() {
    local last now
    last="${STATE_DIR}/sjv-backup-wal.epoch"
    now="$(date +%s)"
    [[ -f "${last}" ]] || return 0
    (( now - $(<"${last}") >= WAL_INTERVAL ))
}

mark_wal() {
    printf '%s\n' "$(date +%s)" > "${STATE_DIR}/sjv-backup-wal.epoch"
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
    *)
        log_msg "usage: sjv-backup supervise | run daily|wal | health"
        exit 2
        ;;
esac
