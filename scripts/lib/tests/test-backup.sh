#!/usr/bin/env bash
# Offline checks for the permanent backup service. No repository is contacted.
# shellcheck disable=SC2016

backup_script() {
    printf '%s\n' "${REPO_ROOT}/backup/sjv-backup.sh"
}

backup_compose() {
    printf '%s\n' "${REPO_ROOT}/compose/30-backup.yml"
}

backup_prepare_tree() {
    local root="$1" secret="fixture-restic-key-not-logged"
    mkdir -p "${root}/bin" "${root}/locks" "${root}/state" "${root}/backup/pgbackrest/archive" \
        "${root}/backup/dumps" "${root}/backup/files" "${root}/certs" "${root}/run"
    printf '%s\n' "${secret}" > "${root}/key"
    chmod 600 "${root}/key"
    printf '%s\n' "fixture-certificate" > "${root}/certs/rest-server.crt"
    chmod 644 "${root}/certs/rest-server.crt"
    cat > "${root}/bin/restic-stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${STUB_LOG}"
if [[ "${1:-}" == forget || "${1:-}" == prune ]]; then
    printf '%s\n' "forbidden-subcommand" >> "${STUB_LOG}"
    exit 99
fi
if [[ "${RESTIC_REPOSITORY:-}" == *@* ]]; then
    printf '%s\n' "repository-url-still-has-user" >> "${STUB_LOG}"
fi
if [[ -n "${RESTIC_REST_USERNAME:-}" ]]; then
    printf '%s\n' "rest-username=${RESTIC_REST_USERNAME}" >> "${STUB_LOG}"
fi
if [[ -n "${RESTIC_REST_PASSWORD:-}" ]]; then
    printf '%s\n' "rest-password-present" >> "${STUB_LOG}"
fi
if [[ -n "${RESTIC_PASSWORD_FILE:-}" && -f "${RESTIC_PASSWORD_FILE}" ]]; then
    printf '%s\n' "key-file-present" >> "${STUB_LOG}"
fi
if [[ -n "${STUB_OVERLAP_DIR:-}" ]]; then
    if ! mkdir "${STUB_OVERLAP_DIR}" 2>/dev/null; then
        printf '%s\n' "overlap" >> "${STUB_LOG}"
        exit 97
    fi
    trap 'rmdir "${STUB_OVERLAP_DIR}" 2>/dev/null || true' EXIT
fi
sleep "${STUB_SLEEP:-0}"
exit "${STUB_EXIT:-0}"
EOF
    chmod 755 "${root}/bin/restic-stub"
}

backup_pids_dead() {
    local pid
    for pid in "$@"; do
        [[ -n "${pid}" ]] || continue
        if kill -0 "${pid}" 2>/dev/null; then
            return 1
        fi
    done
    return 0
}

# The holder must be started in this shell. A command substitution would
# exit and drop the lock with it.
BACKUP_HOLDER=""

backup_hold_exclusive() {
    local file="$1" attempt=0
    BACKUP_HOLDER=""
    : > "${file}"
    set -m
    flock -x "${file}" sleep 180 &
    BACKUP_HOLDER=$!
    set +m
    while flock -n -x "${file}" true 2>/dev/null; do
        attempt=$(( attempt + 1 ))
        if [[ "${attempt}" -ge 50 ]]; then
            backup_stop_group "${BACKUP_HOLDER}"
            BACKUP_HOLDER=""
            return 1
        fi
        sleep 0.05
    done
}

backup_stop_group() {
    local pid="${1:-}"
    [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || return 0
    kill -TERM -"${pid}" 2>/dev/null || kill -TERM "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
}

backup_wait_grep() {
    local pattern="$1" file="$2" tries="${3:-80}" i=0
    while [[ "${i}" -lt "${tries}" ]]; do
        if [[ -f "${file}" ]] && grep -F -q -- "${pattern}" "${file}"; then
            return 0
        fi
        sleep 0.1
        i=$(( i + 1 ))
    done
    return 1
}

backup_env() {
    local root="$1"
    BACKUP_ENV=(
        "SJV_BACKUP_ROOT=${root}/backup"
        "SJV_BACKUP_LOCK_DIR=${root}/locks"
        "SJV_BACKUP_STATE_DIR=${root}/state"
        "SJV_BACKUP_HEARTBEAT=${root}/run/heartbeat"
        "SJV_BACKUP_CACERT=${root}/certs/rest-server.crt"
        "SJV_BACKUP_RESTIC=${root}/bin/restic-stub"
        "SJV_BACKUP_LOCK_WAIT=1"
        "RESTIC_PASSWORD_FILE=${root}/key"
        "RESTIC_REPOSITORY=rest:https://infrastructure-sjv@10.100.101.12:8000/infrastructure-sjv/"
        "RESTIC_REST_PASSWORD=fixture-rest-password-0123"
        "STUB_LOG=${root}/stub.log"
        "STUB_EXIT=${2:-0}"
        "STUB_SLEEP=${3:-0}"
    )
}

test_backup_compose() {
    print_section "Backup service"
    local compose script hits
    compose="$(backup_compose)"
    script="$(backup_script)"
    t_check "compose includes the backup service" grep -q 'compose/30-backup.yml' "${REPO_ROOT}/compose.yml"
    t_check "the service is named sjv-backup" grep -q 'container_name: sjv-backup' "${compose}"
    t_check "the service stays running" grep -q 'restart: unless-stopped' "${compose}"
    t_check "the service joins only the egress network" \
        bash -c 'grep -q "sjv-egress" "$1" && ! grep -q "sjv-proxy" "$1" && ! grep -q "sjv-internal" "$1" && ! grep -q "sjv-mqtt" "$1"' _ "${compose}"
    t_check "the service publishes no port" bash -c '! grep -q "ports:" "$1"' _ "${compose}"
    t_check "the service drops new privileges" grep -q 'no-new-privileges:true' "${compose}"
    t_check "the TLS certificate is mounted read-only" grep -q '/certs/rest-server.crt:ro' "${compose}"
    t_check "pgBackRest, dumps and files are mounted read-only" \
        bash -c 'grep -q "/backup/pgbackrest:ro" "$1" && grep -q "/backup/dumps:ro" "$1" && grep -q "/backup/files:ro" "$1"' _ "${compose}"
    t_check "the repository key uses RESTIC_PASSWORD_FILE" grep -q 'RESTIC_PASSWORD_FILE:' "${compose}"
    t_check "Restic is pinned to 0.19.1" grep -q 'infrastructure-sjv/sjv-backup:0.19.1' "${compose}"
    t_check "the scheduler script parses" bash -n "${script}"
    t_check "the image build installs util-linux and checks flock" \
        bash -c 'grep -q "util-linux" "$1" && grep -q "flock --version | grep -q '"'"'util-linux'"'"'" "$1"' _ "${REPO_ROOT}/backup/Dockerfile"
    hits="$(grep -nE '(^|[[:space:]])(forget|prune|--insecure-tls|-k)([[:space:]]|$)' "${script}" "${REPO_ROOT}/backup/Dockerfile" || true)"
    t_check "the client does not forget, prune or disable TLS" test -z "${hits}"
    [[ -z "${hits}" ]] || printf '    %s\n' "${hits}"
    t_check "daily and wal are both scheduled" \
        bash -c 'grep -q "backup_run daily" "$1" && grep -q "backup_run wal" "$1" && grep -q "WAL_INTERVAL" "$1" && grep -q "03:15" "$1"' _ "${script}"
    t_check "jobs take an exclusive lock" grep -q 'flock -n 9' "${script}"
    t_check "daily takes the local locks without waiting" \
        bash -c 'grep -F -q "flock -s -n 7" "$1" && grep -F -q "flock -s -n 8" "$1"' _ "${script}"
    t_check "wal still waits for the repository lock" \
        grep -F -q 'flock -s -w "${LOCK_WAIT}" 8' "${script}"
}

test_backup_run() {
    print_section "Backup jobs without a repository"
    local root secret="fixture-rest-password-0123"
    root="${T_RUN_DIR}/backup-case"
    if [[ -d "${root}" ]]; then
        find "${root}" -mindepth 1 -delete
    fi
    backup_prepare_tree "${root}"
    backup_env "${root}" 0 0
    rm -f "${root}/stub.log"
    t_run env "${BACKUP_ENV[@]}" RESTIC_REST_PASSWORD= bash "${REPO_ROOT}/backup/sjv-backup.sh" run wal
    t_check "a missing rest-server password does not start Restic" \
        bash -c '(( $1 == 0 )) && grep -q "\"status\":\"not-configured\"" "$2" && [[ ! -e "$3" ]]' \
        _ "${T_RC}" "${root}/state/sjv-backup-wal.json" "${root}/stub.log"
    t_check "a missing rest-server password is not written to the log or state" \
        bash -c '! printf "%s\n" "$1" | grep -F -q -e "fixture-restic-key-not-logged" && ! grep -F -q -e "fixture-restic-key-not-logged" "$2" && ! grep -F -q -e "fixture-rest-password-0123" "$2"' \
        _ "${T_OUT}" "${root}/state/sjv-backup-wal.json"

    rm -f "${root}/stub.log" "${root}/state/sjv-backup-wal.json"
    backup_env "${root}" 0 0
    t_run env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" run wal
    t_check "an empty WAL archive does not start Restic" \
        bash -c '(( $1 == 0 )) && grep -q "\"status\":\"skipped-empty\"" "$2" && [[ ! -e "$3" ]]' \
        _ "${T_RC}" "${root}/state/sjv-backup-wal.json" "${root}/stub.log"
    printf 'temporary\n' > "${root}/backup/pgbackrest/archive/000000010000000000000001.pgbackrest.tmp"
    rm -f "${root}/stub.log" "${root}/state/sjv-backup-wal.json"
    t_run env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" run wal
    t_check "a temporary WAL file is not a backup" \
        bash -c '(( $1 == 0 )) && grep -q "\"status\":\"skipped-empty\"" "$2" && [[ ! -e "$3" ]]' \
        _ "${T_RC}" "${root}/state/sjv-backup-wal.json" "${root}/stub.log"
    rm -f "${root}/backup/pgbackrest/archive/000000010000000000000001.pgbackrest.tmp"

    printf 'outside\n' > "${root}/outside-segment"
    ln -s "${root}/outside-segment" "${root}/backup/pgbackrest/archive/0000000100000000000000AA"
    rm -f "${root}/stub.log" "${root}/state/sjv-backup-wal.json"
    t_run env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" run wal
    t_check "a symlink to a file outside the archive is not a WAL segment" \
        bash -c '(( $1 == 0 )) && grep -q "\"status\":\"skipped-empty\"" "$2" && [[ ! -e "$3" ]]' \
        _ "${T_RC}" "${root}/state/sjv-backup-wal.json" "${root}/stub.log"
    rm -f "${root}/backup/pgbackrest/archive/0000000100000000000000AA" "${root}/outside-segment"

    printf 'temporary\n' > "${root}/outside-segment.pgbackrest.tmp"
    ln -s "${root}/outside-segment.pgbackrest.tmp" "${root}/backup/pgbackrest/archive/0000000100000000000000BB"
    rm -f "${root}/stub.log" "${root}/state/sjv-backup-wal.json"
    t_run env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" run wal
    t_check "a symlink to a temporary WAL file is not a backup" \
        bash -c '(( $1 == 0 )) && grep -q "\"status\":\"skipped-empty\"" "$2" && [[ ! -e "$3" ]]' \
        _ "${T_RC}" "${root}/state/sjv-backup-wal.json" "${root}/stub.log"
    rm -f "${root}/backup/pgbackrest/archive/0000000100000000000000BB" "${root}/outside-segment.pgbackrest.tmp"

    mkdir -p "${root}/backup/pgbackrest/archive/sjv/18-1"
    printf 'segment\n' > "${root}/backup/pgbackrest/archive/sjv/18-1/000000010000000000000001"
    rm -f "${root}/stub.log" "${root}/state/sjv-backup-wal.json"
    t_run env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" run wal
    t_check "a regular WAL file in a nested directory is backed up" \
        bash -c '(( $1 == 0 )) && grep -q "\"status\":\"ok\"" "$2" && grep -q "/pgbackrest/archive" "$3" && grep -q -- "--tag wal" "$3"' \
        _ "${T_RC}" "${root}/state/sjv-backup-wal.json" "${root}/stub.log"
    find "${root}/backup/pgbackrest/archive" -mindepth 1 -delete
    rm -f "${root}/stub.log" "${root}/state/sjv-backup-wal.json"

    printf '%s\n' "$(date +%F)" > "${root}/state/sjv-backup-daily.date"
    rm -f "${root}/stub.log" "${root}/state/sjv-backup-wal.json" "${root}/state/sjv-backup-wal.epoch"
    backup_env "${root}" 0 0
    BACKUP_ENV+=("SJV_BACKUP_TICK_SECONDS=1" "SJV_BACKUP_WAL_SECONDS=3" "SJV_BACKUP_HEARTBEAT_SECONDS=30")
    env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" supervise >/dev/null 2>&1 &
    local scheduler=$!
    local attempt=0
    while [[ ! -f "${root}/state/sjv-backup-wal.epoch" && "${attempt}" -lt 20 ]]; do
        sleep 0.2
        attempt=$(( attempt + 1 ))
    done
    t_check "the scheduler records an empty WAL attempt" test -f "${root}/state/sjv-backup-wal.epoch"
    t_check "the scheduler does not call Restic for an empty archive" test ! -e "${root}/stub.log"
    local first_epoch="" second_epoch=""
    [[ -f "${root}/state/sjv-backup-wal.epoch" ]] && first_epoch="$(<"${root}/state/sjv-backup-wal.epoch")"
    sleep 1.2
    second_epoch="$(<"${root}/state/sjv-backup-wal.epoch")"
    t_check "an empty WAL is not tried again inside the interval" test "${first_epoch}" = "${second_epoch}"
    local -a live=()
    mapfile -t live < <(ps -o pid= --ppid "${scheduler}" 2>/dev/null | awk '{print $1}')
    local -a beats=()
    if [[ -n "${live[0]:-}" ]]; then
        mapfile -t beats < <(ps -o pid= --ppid "${live[0]}" 2>/dev/null | awk '{print $1}')
    fi
    t_check "the scheduler has a heartbeat process" test "${#live[@]}" -ge 1
    sleep 3
    second_epoch="$(<"${root}/state/sjv-backup-wal.epoch")"
    t_check "the next empty WAL check waits for the interval" test "${first_epoch}" != "${second_epoch}"
    kill -TERM "${scheduler}"
    wait "${scheduler}" || true
    sleep 0.2
    t_check "SIGTERM stops the scheduler and its heartbeat" \
        backup_pids_dead "${scheduler}" "${live[@]}" "${beats[@]}"

    printf 'segment\n' > "${root}/backup/pgbackrest/archive/000000010000000000000001"
    backup_env "${root}" 0 0
    t_run env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" run wal
    t_check "a wal job succeeds against the stub" test "${T_RC}" -eq 0
    t_check "the wal job asks for tag wal and the archive only" \
        bash -c 'grep -q "backup --exclude \*.pgbackrest.tmp --tag wal" "$1" && grep -q "/archive" "$1"' _ "${root}/stub.log"
    t_check "the repository URL given to the client has no user" \
        bash -c 'grep -q -- "--tag wal" "$1" && ! grep -q "repository-url-still-has-user" "$1"' _ "${root}/stub.log"
    t_check "the rest-server username is passed beside the URL" grep -q 'rest-username=infrastructure-sjv' "${root}/stub.log"
    t_check "backup and snapshots both receive the CA certificate" \
        bash -c 'c="--cacert $2"; grep -F -q -- "$c backup" "$1" && grep -F -q -- "$c snapshots" "$1"' \
        _ "${root}/stub.log" "${root}/certs/rest-server.crt"
    t_check "the rest-server password is present but not printed" \
        bash -c 'grep -q "rest-password-present" "$1" && ! grep -F -q -e "$2" "$1" && ! printf "%s\n" "$3" | grep -F -q -e "$2"' _ "${root}/stub.log" "${secret}" "${T_OUT}"
    t_check "a successful job is recorded as ok" grep -q '"status":"ok"' "${root}/state/sjv-backup-wal.json"
    t_check "the job log does not contain the repository key" \
        bash -c '! printf "%s\n" "$1" | grep -F -q -e "fixture-restic-key-not-logged"' _ "${T_OUT}"

    rm -f "${root}/stub.log"
    backup_env "${root}" 1 0
    t_run env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" run daily
    t_check "a failed backup is not reported as success" \
        bash -c '(( $1 != 0 )) && grep -q "\"status\":\"failed\"" "$2"' _ "${T_RC}" "${root}/state/sjv-backup-daily.json"
    t_check "the failed job log does not contain the rest-server password" \
        bash -c '! printf "%s\n" "$2" | grep -F -q -e "$1"' _ "${secret}" "${T_OUT}"

    rm -f "${root}/stub.log"
    backup_env "${root}" 0 2
    env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" run wal >/dev/null 2>&1 &
    local first=$!
    sleep 0.5
    t_run env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" run daily
    wait "${first}" || true
    t_check "a second job does not start while the first holds the lock" \
        bash -c '(( $1 == 75 )) && grep -q "skipped-locked" "$2"' _ "${T_RC}" "${root}/state/sjv-backup-daily.json"

    backup_env "${root}" 0 8
    BACKUP_ENV+=("SJV_BACKUP_HEALTH_MAX_AGE=3" "SJV_BACKUP_HEARTBEAT_SECONDS=1")
    env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" run wal >/dev/null 2>&1 &
    local long_job=$!
    sleep 4
    t_check "the long backup is still running" kill -0 "${long_job}"
    t_run env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" health
    t_check "a long backup does not fail the health check" test "${T_RC}" -eq 0
    local now stamp age
    now="$(date +%s)"
    stamp="$(<"${root}/run/heartbeat")"
    age=$(( now - stamp ))
    t_check "the heartbeat stays current during a long backup" test "${age}" -lt 3
    local -a running=() nested=() child
    mapfile -t running < <(ps -o pid= --ppid "${long_job}" 2>/dev/null | awk '{print $1}')
    for child in "${running[@]}"; do
        mapfile -t -O "${#nested[@]}" nested < <(ps -o pid= --ppid "${child}" 2>/dev/null | awk '{print $1}')
    done
    wait "${long_job}" || true
    sleep 0.2
    t_check "a finished backup leaves no heartbeat process" \
        backup_pids_dead "${long_job}" "${running[@]}" "${nested[@]}"
    printf '%s\n' 1 > "${root}/run/heartbeat"
    t_run env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" health
    t_check "a stale heartbeat is unhealthy" test "${T_RC}" -ne 0
}

test_backup_locks() {
    print_section "Backup locks do not block WAL"
    local root holder="" scheduler=0 started=0 elapsed=0 first_epoch="" later_epoch=""
    root="${T_RUN_DIR}/backup-locks"
    backup_prepare_tree "${root}"
    mkdir -p "${root}/backup/pgbackrest/archive/sjv/18-1"
    printf 'segment\n' > "${root}/backup/pgbackrest/archive/sjv/18-1/000000010000000000000001"
    if ! backup_hold_exclusive "${root}/locks/backup.lock"; then
        t_fail "the test could not hold backup.lock"
        return 0
    fi
    holder="${BACKUP_HOLDER}"
    backup_env "${root}" 0 1
    BACKUP_ENV+=(
        "SJV_BACKUP_TICK_SECONDS=1"
        "SJV_BACKUP_WAL_SECONDS=3"
        "SJV_BACKUP_DAILY_AT=00:00"
        "SJV_BACKUP_LOCK_WAIT=30"
        "SJV_BACKUP_HEARTBEAT_SECONDS=30"
        "STUB_OVERLAP_DIR=${root}/stub-overlap"
    )
    rm -f "${root}/stub.log" "${root}/state/sjv-backup-daily.json" "${root}/state/sjv-backup-wal.json" \
        "${root}/state/sjv-backup-wal.epoch" "${root}/state/sjv-backup-daily.date"
    started="$(date +%s)"
    env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" supervise >/dev/null 2>&1 &
    scheduler=$!
    if backup_wait_grep '"status":"ok"' "${root}/state/sjv-backup-wal.json" 150; then
        elapsed="$(( $(date +%s) - started ))"
    else
        elapsed=999
    fi
    t_check "a busy backup.lock skips daily without waiting" \
        bash -c '[[ -f "$1" ]] && grep -F -q "\"status\":\"skipped-backup-lock\"" "$1" && (( $2 < 12 ))' \
        _ "${root}/state/sjv-backup-daily.json" "${elapsed}"
    t_check "WAL runs while the local backup lock is held" \
        bash -c '[[ -f "$1" ]] && grep -F -q -- "--tag wal" "$1" && ! grep -F -q -- "--tag daily" "$1" && ! grep -F -q overlap "$1"' \
        _ "${root}/stub.log"
    local attempt=0
    while [[ ! -f "${root}/state/sjv-backup-wal.epoch" && "${attempt}" -lt 30 ]]; do
        sleep 0.1
        attempt=$(( attempt + 1 ))
    done
    [[ -f "${root}/state/sjv-backup-wal.epoch" ]] && first_epoch="$(<"${root}/state/sjv-backup-wal.epoch")"
    sleep 1.2
    [[ -f "${root}/state/sjv-backup-wal.epoch" ]] && later_epoch="$(<"${root}/state/sjv-backup-wal.epoch")"
    t_check "WAL is not started again inside its interval while backup.lock is held" \
        bash -c '[[ -n "$1" && "$1" == "$2" ]]' _ "${first_epoch}" "${later_epoch}"
    later_epoch="${first_epoch}"
    attempt=0
    while [[ "${attempt}" -lt 100 ]]; do
        [[ -f "${root}/state/sjv-backup-wal.epoch" ]] && later_epoch="$(<"${root}/state/sjv-backup-wal.epoch")"
        [[ -n "${first_epoch}" && "${later_epoch}" != "${first_epoch}" ]] && break
        sleep 0.1
        attempt=$(( attempt + 1 ))
    done
    t_check "the next WAL still runs on its interval while backup.lock is held" \
        bash -c '[[ -n "$1" && "$1" != "$2" ]]' _ "${first_epoch}" "${later_epoch}"
    t_check "restic jobs do not overlap while backup.lock is held" \
        bash -c '[[ -f "$1" ]] && ! grep -F -q overlap "$1"' _ "${root}/stub.log"
    t_check "the local backup lock stays held" \
        bash -c '! flock -n -x "$1" true' _ "${root}/locks/backup.lock"
    backup_stop_group "${scheduler}"
    sleep 0.2
    t_check "the restic job lock is free after daily skipped and the scheduler stopped" \
        flock -n -x "${root}/locks/restic-job.lock" true
    backup_stop_group "${holder}"

    holder=""
    scheduler=0
    root="${T_RUN_DIR}/repo-locks"
    backup_prepare_tree "${root}"
    mkdir -p "${root}/backup/pgbackrest/archive/sjv/18-1"
    printf 'segment\n' > "${root}/backup/pgbackrest/archive/sjv/18-1/000000010000000000000001"
    if ! backup_hold_exclusive "${root}/locks/repo.lock"; then
        t_fail "the test could not hold repo.lock"
        return 0
    fi
    holder="${BACKUP_HOLDER}"
    backup_env "${root}" 0 0
    started="$(date +%s)"
    t_run env "${BACKUP_ENV[@]}" SJV_BACKUP_LOCK_WAIT=30 bash "${REPO_ROOT}/backup/sjv-backup.sh" run daily
    elapsed="$(( $(date +%s) - started ))"
    t_check "a busy repo.lock skips daily without waiting" \
        bash -c '(( $1 == 75 )) && grep -F -q "\"status\":\"skipped-repo-lock\"" "$2" && (( $3 < 8 ))' \
        _ "${T_RC}" "${root}/state/sjv-backup-daily.json" "${elapsed}"
    backup_env "${root}" 0 0
    BACKUP_ENV+=(
        "SJV_BACKUP_TICK_SECONDS=1"
        "SJV_BACKUP_WAL_SECONDS=60"
        "SJV_BACKUP_DAILY_AT=00:00"
        "SJV_BACKUP_LOCK_WAIT=1"
        "SJV_BACKUP_HEARTBEAT_SECONDS=30"
    )
    rm -f "${root}/state/sjv-backup-daily.json" "${root}/state/sjv-backup-wal.json" \
        "${root}/state/sjv-backup-daily.attempt" "${root}/stub.log"
    printf '%s\n' "$(date +%s)" > "${root}/state/sjv-backup-wal.epoch"
    env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" supervise >/dev/null 2>&1 &
    scheduler=$!
    backup_wait_grep '"status":"skipped-repo-lock"' "${root}/state/sjv-backup-daily.json" 80 || true
    sleep 0.2
    t_check "a skipped daily releases the restic job lock" \
        flock -n -x "${root}/locks/restic-job.lock" true
    t_check "a skipped daily releases the backup lock" \
        flock -n -x "${root}/locks/backup.lock" true
    t_check "repo.lock stays held by the local expire lock" \
        bash -c '! flock -n -x "$1" true' _ "${root}/locks/repo.lock"
    printf '%s\n' 0 > "${root}/state/sjv-backup-wal.epoch"
    backup_wait_grep '"status":"skipped-repo-lock"' "${root}/state/sjv-backup-wal.json" 80 || true
    t_check "the scheduler continues and WAL skips a busy repository lock" \
        bash -c 'kill -0 "$1" && [[ -f "$2" ]] && grep -F -q "\"status\":\"skipped-repo-lock\"" "$2" && [[ ! -e "$3" ]]' \
        _ "${scheduler}" "${root}/state/sjv-backup-wal.json" "${root}/stub.log"
    backup_stop_group "${scheduler}"
    backup_stop_group "${holder}"
}

test_backup_image() {
    print_section "Backup image flock"
    local runtime=""
    if command -v docker >/dev/null 2>&1; then
        runtime=docker
    elif command -v podman >/dev/null 2>&1; then
        runtime=podman
    fi
    if [[ -z "${runtime}" ]]; then
        t_skip "flock inside the built image; no container engine is installed"
        return 0
    fi
    local tag="infrastructure-sjv-backup-test:0.19.1" version
    if ! version="$(${runtime} build --quiet -t "${tag}" "${REPO_ROOT}/backup" 2>&1)"; then
        t_fail "the backup image did not build"
        printf '    %s\n' "${version}"
        return 0
    fi
    version="$(${runtime} run --rm --entrypoint flock "${tag}" --version 2>&1 || true)"
    t_check "the built image provides util-linux flock" \
        bash -c '[[ "$1" == *util-linux* ]]' _ "${version}"
    ${runtime} image rm "${tag}" >/dev/null 2>&1 || true
}

run_backup_tests() {
    print_header "Remote backup"
    test_backup_compose
    test_backup_run
    test_backup_locks
    test_backup_image
}
