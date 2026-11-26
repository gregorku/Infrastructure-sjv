#!/bin/bash
# Scheduler and Restic client for the permanent sjv-backup container.
# Runs daily and wal backups. Never forget, prune, or delete snapshots.
set -Eeuo pipefail
# jq programs intentionally use single quotes; their variables are jq variables.
# shellcheck disable=SC2016

readonly BACKUP_ROOT="${SJV_BACKUP_ROOT:-/backup}"
readonly PREPARATIONS="${BACKUP_ROOT}/preparations"
readonly CURRENT_PREPARATION="${PREPARATIONS}/current"
readonly LOCK_DIR="${SJV_BACKUP_LOCK_DIR:-/locks}"
readonly STATE_DIR="${SJV_BACKUP_STATE_DIR:-/state}"
readonly HEARTBEAT="${SJV_BACKUP_HEARTBEAT:-/run/sjv-backup/heartbeat}"
readonly PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-/run/secrets/restic-key-password}"
readonly CACERT="${SJV_BACKUP_CACERT:-/certs/rest-server.crt}"
readonly RESTIC_BIN="${SJV_BACKUP_RESTIC:-restic}"
readonly JQ_BIN="${SJV_BACKUP_JQ:-jq}"
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
readonly LAST_RESTORABLE="${STATE_DIR}/sjv-backup-last-restorable.json"
readonly LAST_ATTEMPT="${STATE_DIR}/sjv-backup-last-attempt.json"
readonly DAILY_FAILURES="${STATE_DIR}/sjv-backup-daily.failures"

CHILD=0
HEARTBEAT_PID=0
DAILY_PREPARATION_ID=""
DAILY_PREPARATION_DIR=""
DAILY_DUMP_FILE=""
DAILY_APP_KEK_STATE=""
DAILY_ACME_STATE=""
DAILY_HTPASSWD_STATE=""
DAILY_BOUNCER_STATE=""

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
    local mode="$1" status="$2" code="$3" path body
    path="${STATE_DIR}/sjv-backup-${mode}.json"
    body="$(printf '{"mode":"%s","status":"%s","exit_code":%s,"finished_at":"%s"}' \
        "$(json_escape "${mode}")" "$(json_escape "${status}")" "${code}" \
        "$(json_escape "$(date -u +%Y-%m-%dT%H:%M:%SZ)")")"
    state_write_atomic "${path}" "${body}"
}

write_daily_state() {
    local status="$1" code="$2" preparation_id="$3" tag="$4" snapshot_id="$5"
    local started="$6" finished="$7" duration="$8" path="${STATE_DIR}/sjv-backup-daily.json" body
    body="$(printf '{"mode":"daily","status":"%s","exit_code":%s,"preparation_id":"%s","snapshot_tag":"%s","snapshot_id":"%s","started_at":"%s","finished_at":"%s","duration_seconds":%s}' \
        "$(json_escape "${status}")" "${code}" "$(json_escape "${preparation_id}")" \
        "$(json_escape "${tag}")" "$(json_escape "${snapshot_id}")" \
        "$(json_escape "${started}")" "$(json_escape "${finished}")" "${duration}")"
    state_write_atomic "${path}" "${body}"
}

daily_failure_count() {
    local count=0
    if [[ -f "${DAILY_FAILURES}" && ! -L "${DAILY_FAILURES}" ]]; then
        count="$(<"${DAILY_FAILURES}")"
    fi
    [[ "${count}" =~ ^[0-9]+$ ]] || count=0
    printf '%s\n' "${count}"
}

write_daily_failures() {
    state_write_atomic "${DAILY_FAILURES}" "$1"
}

write_daily_attempt() {
    local status="$1" code="$2" preparation_id="$3" tag="$4" snapshot_id="$5"
    local started="$6" finished="$7" duration="$8" failures="$9" body
    body="$(printf '{"mode":"daily","status":"%s","exit_code":%s,"preparation_id":"%s","snapshot_tag":"%s","snapshot_id":"%s","started_at":"%s","finished_at":"%s","duration_seconds":%s,"consecutive_failures":%s}' \
        "$(json_escape "${status}")" "${code}" "$(json_escape "${preparation_id}")" \
        "$(json_escape "${tag}")" "$(json_escape "${snapshot_id}")" \
        "$(json_escape "${started}")" "$(json_escape "${finished}")" \
        "${duration}" "${failures}")"
    state_write_atomic "${LAST_ATTEMPT}" "${body}"
}

json_escape() {
    local value="$1" char hex i
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    for ((i = 1; i <= 31; i++)); do
        printf -v hex '%02x' "${i}"
        printf -v char '%b' "\\x${hex}"
        value="${value//${char}/\\u00${hex}}"
    done
    printf '%s' "${value}"
}

state_prepare_dir() {
    [[ -e "${STATE_DIR}" && ! -L "${STATE_DIR}" ]] || {
        [[ ! -e "${STATE_DIR}" ]] && mkdir -m 700 -- "${STATE_DIR}"
    }
    [[ -d "${STATE_DIR}" && ! -L "${STATE_DIR}" ]] || return 1
    [[ "$(stat -c '%u' "${STATE_DIR}")" == "${EUID}" ]] || return 1
    [[ "$(stat -c '%a' "${STATE_DIR}")" == 700 ]] || return 1
}

state_write_atomic() {
    local path="$1" body="$2" dir base tmp
    state_prepare_dir || return 1
    dir="$(dirname -- "${path}")"
    [[ "${dir}" == "${STATE_DIR}" ]] || return 1
    base="$(basename -- "${path}")"
    [[ "${base}" != . && "${base}" != .. ]] || return 1
    [[ ! -L "${path}" && ! -d "${path}" ]] || return 1
    tmp="$(mktemp "${dir}/.${base}.XXXXXX")" || return 1
    if ! chmod 600 -- "${tmp}" ||
        ! printf '%s\n' "${body}" > "${tmp}" ||
        [[ "$(stat -c '%a' "${tmp}")" != 600 ]] ||
        [[ -L "${path}" || -d "${path}" ]] ||
        ! mv -f -- "${tmp}" "${path}"; then
        rm -f -- "${tmp}"
        return 1
    fi
    return 0
}

daily_record() {
    local status="$1" code="$2" preparation_id="$3" tag="$4" snapshot_id="$5"
    local started_at="$6" started_epoch="$7" failures="$8"
    local finished_epoch finished_at duration
    finished_epoch="$(date +%s)"
    finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    duration="$(( finished_epoch - started_epoch ))"
    write_daily_failures "${failures}"
    write_daily_state "${status}" "${code}" "${preparation_id}" "${tag}" \
        "${snapshot_id}" "${started_at}" "${finished_at}" "${duration}"
    write_daily_attempt "${status}" "${code}" "${preparation_id}" "${tag}" \
        "${snapshot_id}" "${started_at}" "${finished_at}" "${duration}" "${failures}"
}

daily_preparation() {
    local preparation_id="" preparation_dir="" manifest="" dump_file="" app_kek_state=""
    [[ -d "${PREPARATIONS}" && ! -L "${PREPARATIONS}" ]] || return 1
    [[ -f "${CURRENT_PREPARATION}" && ! -L "${CURRENT_PREPARATION}" ]] || return 1
    [[ "$(stat -c '%a' "${CURRENT_PREPARATION}")" == 600 && "$(stat -c '%u' "${CURRENT_PREPARATION}")" == "${EUID}" ]] || return 1
    IFS= read -r preparation_id < "${CURRENT_PREPARATION}" || return 1
    [[ -n "${preparation_id}" && "${preparation_id}" != "." && "${preparation_id}" != ".." ]] || return 1
    [[ "${preparation_id}" != *[/\\]* ]] || return 1
    [[ "${preparation_id}" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    preparation_dir="${PREPARATIONS}/${preparation_id}"
    [[ "$(dirname -- "${preparation_dir}")" == "${PREPARATIONS}" ]] || return 1
    [[ -d "${preparation_dir}" && ! -L "${preparation_dir}" ]] || return 1
    local preparations_real preparation_real
    preparations_real="$(readlink -f -- "${PREPARATIONS}")" || return 1
    preparation_real="$(readlink -f -- "${preparation_dir}")" || return 1
    [[ "$(dirname -- "${preparation_real}")" == "${preparations_real}" ]] || return 1
    [[ "$(basename -- "${preparation_real}")" == "${preparation_id}" ]] || return 1
    [[ "$(stat -c '%u' "${preparation_dir}")" == "${EUID}" ]] || return 1
    ! find "${preparation_dir}" -xdev -type l -print -quit | grep -q . || return 1
    manifest="${preparation_dir}/backup-manifest.json"
    [[ -f "${manifest}" && ! -L "${manifest}" ]] || return 1
    # shellcheck disable=SC2016
    "${JQ_BIN}" -e --arg id "${preparation_id}" '
        .schema == 1 and .preparation_id == $id and .status == "ready" and
        .pgbackrest == "ok" and .pg_dump == "ok" and
        .runtime_config == "ok" and .wal_archive == "ok" and
        (.app_kek == "copied" or .app_kek == "not_required") and
        ((.acme // "absent") == "copied" or (.acme // "absent") == "absent") and
        ((.dashboard_htpasswd // "absent") == "copied" or (.dashboard_htpasswd // "absent") == "absent") and
        ((.crowdsec_bouncer_key // "absent") == "copied" or (.crowdsec_bouncer_key // "absent") == "absent") and
        (.dump_file | type == "string")
    ' "${manifest}" >/dev/null || return 1
    dump_file="$("${JQ_BIN}" -r '.dump_file' "${manifest}")"
    [[ "${dump_file}" =~ ^sjv-[0-9]{8}T[0-9]{6}Z(-[0-9]+)?\.dump$ ]] || return 1
    [[ -f "${preparation_dir}/dumps/${dump_file}" && ! -L "${preparation_dir}/dumps/${dump_file}" ]] || return 1
    [[ "$(stat -c '%a' "${preparation_dir}/dumps/${dump_file}")" == 600 && "$(stat -c '%u' "${preparation_dir}/dumps/${dump_file}")" == "${EUID}" ]] || return 1
    [[ -f "${preparation_dir}/files/runtime.env" && ! -L "${preparation_dir}/files/runtime.env" ]] || return 1
    [[ "$(stat -c '%a' "${manifest}")" == 600 && "$(stat -c '%u' "${manifest}")" == "${EUID}" ]] || return 1
    [[ "$(stat -c '%a' "${preparation_dir}/files/runtime.env")" == 600 && "$(stat -c '%u' "${preparation_dir}/files/runtime.env")" == "${EUID}" ]] || return 1
    app_kek_state="$("${JQ_BIN}" -r '.app_kek' "${manifest}")"
    DAILY_DUMP_FILE="${dump_file}"
    DAILY_APP_KEK_STATE="${app_kek_state}"
    if [[ "${app_kek_state}" == copied ]]; then
        [[ -f "${preparation_dir}/files/app-kek" && ! -L "${preparation_dir}/files/app-kek" ]] || return 1
        [[ "$(stat -c '%a' "${preparation_dir}/files/app-kek")" == 600 && "$(stat -c '%u' "${preparation_dir}/files/app-kek")" == "${EUID}" && "$(stat -c '%s' "${preparation_dir}/files/app-kek")" == 32 ]] || return 1
    fi
    local optional_state optional_name optional_file
    for optional_name in acme dashboard_htpasswd crowdsec_bouncer_key; do
        optional_state="$("${JQ_BIN}" -r ".${optional_name} // \"absent\"" "${manifest}")" || return 1
        case "${optional_name}" in
            acme) optional_file="${preparation_dir}/files/acme.json" ;;
            dashboard_htpasswd) optional_file="${preparation_dir}/files/dashboard.htpasswd" ;;
            crowdsec_bouncer_key) optional_file="${preparation_dir}/files/crowdsec-bouncer-key" ;;
        esac
        case "${optional_state}" in
            copied)
                [[ -f "${optional_file}" && ! -L "${optional_file}" ]] || return 1
                [[ "$(stat -c '%a' "${optional_file}")" == 600 && "$(stat -c '%u' "${optional_file}")" == "${EUID}" ]] || return 1
                ;;
            absent)
                [[ ! -e "${optional_file}" && ! -L "${optional_file}" ]] || return 1
                ;;
            *) return 1 ;;
        esac
        case "${optional_name}" in
            acme) DAILY_ACME_STATE="${optional_state}" ;;
            dashboard_htpasswd) DAILY_HTPASSWD_STATE="${optional_state}" ;;
            crowdsec_bouncer_key) DAILY_BOUNCER_STATE="${optional_state}" ;;
        esac
    done
    while IFS= read -r -d '' file; do
        [[ -f "${file}" && ! -L "${file}" ]] || return 1
        [[ "$(stat -c '%a' "${file}")" == 600 && "$(stat -c '%u' "${file}")" == "${EUID}" ]] || return 1
    done < <(find "${preparation_dir}/files" -xdev -type f -print0)
    [[ -d "${BACKUP_ROOT}/pgbackrest" && ! -L "${BACKUP_ROOT}/pgbackrest" ]] || return 1
    DAILY_PREPARATION_ID="${preparation_id}"
    DAILY_PREPARATION_DIR="${preparation_dir}"
    return 0
}

daily_snapshot_id() {
    local tag="$1" output="$2" count
    run_restic --cacert "${CACERT}" snapshots --json --tag "${tag}" > "${output}" || return 1
    count="$("${JQ_BIN}" 'length' "${output}")" || return 1
    [[ "${count}" -le 1 ]] || return 2
    if [[ "${count}" -eq 1 ]]; then
        "${JQ_BIN}" -r '.[0].id' "${output}"
    fi
}

daily_snapshot_contains_manifest() {
    local snapshot_id="$1" output="$2"
    run_restic --cacert "${CACERT}" ls --json "${snapshot_id}" > "${output}" || return 1
    # shellcheck disable=SC2016
    "${JQ_BIN}" -s -e \
        --arg root "/backup/preparations/${DAILY_PREPARATION_ID}" \
        --arg dump "${DAILY_DUMP_FILE}" \
        --arg app_kek "${DAILY_APP_KEK_STATE}" \
        --arg acme "${DAILY_ACME_STATE}" \
        --arg htpasswd "${DAILY_HTPASSWD_STATE}" \
        --arg bouncer "${DAILY_BOUNCER_STATE}" \
        'def has($path): any(.[]; (.path // "") == $path);
         has($root + "/backup-manifest.json") and
         has($root + "/dumps/" + $dump) and
         has($root + "/files/runtime.env") and
         ($app_kek != "copied" or has($root + "/files/app-kek")) and
         ($acme != "copied" or has($root + "/files/acme.json")) and
         ($htpasswd != "copied" or has($root + "/files/dashboard.htpasswd")) and
         ($bouncer != "copied" or has($root + "/files/crowdsec-bouncer-key"))' \
        "${output}" >/dev/null
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

# True only for the Restic 0.19.1 missing-repository result. The command must
# exit 10 and the non-empty lines must be exactly three: the missing config
# file, with an optional Fatal: prefix; the location question; and the
# repository URL left by prepare_repository. Any other status or line is not.
repository_probe_is_absent() {
    local errfile="$1" status="$2" line bare
    local exact="repository does not exist: unable to open config file: <config/> does not exist"
    local -a lines=()
    [[ "${status}" == "10" ]] || return 1
    [[ -f "${errfile}" && ! -L "${errfile}" ]] || return 1
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line%$'\r'}"
        [[ -n "${line}" ]] || continue
        lines+=("${line}")
    done < "${errfile}"
    (( ${#lines[@]} == 3 )) || return 1
    bare="${lines[0]}"
    if [[ "${bare}" == "Fatal: ${exact}" ]]; then
        bare="${exact}"
    fi
    [[ "${bare}" == "${exact}" ]] || return 1
    [[ "${lines[1]}" == "Is there a repository at the following location?" ]] || return 1
    [[ -n "${RESTIC_REPOSITORY:-}" && "${lines[2]}" == "${RESTIC_REPOSITORY}" ]] || return 1
}

INIT_ERRFILE=""

# Replaces every literal occurrence. The pattern is quoted, so * ? [ ]
# in the secret match themselves; backslash-escaping them would look for a
# backslash. The placeholder is not searched again.
redact_literal() {
    local text="$1" secret="$2"
    if [[ -z "${secret}" ]]; then
        printf '%s' "${text}"
        return 0
    fi
    printf '%s' "${text//"${secret}"/"<hidden>"}"
}

# Logs the rejected probe text. Password values, the key-file path and the
# key-file contents are removed first. The absent-repository match is unchanged.
log_probe_diagnostic() {
    local errfile="$1" line redacted secret key_text="" saw=0 i j
    shift
    local -a secrets=()
    for secret in "$@"; do
        [[ -n "${secret}" ]] || continue
        secrets+=("${secret}")
    done
    if [[ -n "${PASSWORD_FILE:-}" && -f "${PASSWORD_FILE}" && ! -L "${PASSWORD_FILE}" ]]; then
        key_text="$(<"${PASSWORD_FILE}")" || true
        [[ -n "${key_text}" ]] && secrets+=("${key_text}")
    fi
    for ((i = 0; i < ${#secrets[@]}; i++)); do
        for ((j = i + 1; j < ${#secrets[@]}; j++)); do
            if ((${#secrets[j]} > ${#secrets[i]})); then
                secret="${secrets[i]}"
                secrets[i]="${secrets[j]}"
                secrets[j]="${secret}"
            fi
        done
    done
    log_msg "init-repository refused: repository probe failed"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line%$'\r'}"
        [[ -n "${line}" ]] || continue
        redacted="${line}"
        for secret in "${secrets[@]+"${secrets[@]}"}"; do
            redacted="$(redact_literal "${redacted}" "${secret}")"
        done
        log_msg "init-repository probe: ${redacted}"
        saw=1
    done < "${errfile}"
    [[ "${saw}" -eq 1 ]] || log_msg "init-repository probe: diagnostic was empty"
}

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
    local saved_rest_password="${RESTIC_REST_PASSWORD:-}" saved_password="${RESTIC_PASSWORD:-}"
    INIT_ERRFILE="$(mktemp)"
    prepare_repository
    run_restic --cacert "${CACERT}" cat config >/dev/null 2>"${INIT_ERRFILE}" || rc=$?
    if [[ "${rc}" -eq 0 ]]; then
        log_msg "init-repository: repository already exists"
        return 0
    fi
    if ! repository_probe_is_absent "${INIT_ERRFILE}" "${rc}"; then
        log_probe_diagnostic "${INIT_ERRFILE}" \
            "${saved_rest_password}" "${saved_password}" \
            "${RESTIC_PASSWORD_FILE:-}" "${PASSWORD_FILE}"
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
    local mode="$1" rc=0 snapshot_rc=0 snapshot_tmp="" ls_tmp="" snapshot_tag="" snapshot_id=""
    local started_epoch="" finished_epoch="" duration="" started_at="" finished_at=""
    local failures=0
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
    if [[ "${mode}" == daily ]]; then
        started_epoch="$(date +%s)"
        started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        if ! daily_preparation; then
            failures="$(( $(daily_failure_count) + 1 ))"
            daily_record "skipped-invalid-preparation" 1 "" "" "" \
                "${started_at}" "${started_epoch}" "${failures}"
            log_msg "daily skipped: current preparation is invalid or incomplete"
            return 1
        fi
        snapshot_tag="sjv-daily-prep-${DAILY_PREPARATION_ID}"
    fi
    mkdir -p "${LOCK_DIR}"
    exec 9>"${JOB_LOCK}"
    if ! flock -n 9; then
        log_msg "${mode} skipped: another backup job holds the lock"
        if [[ "${mode}" == daily ]]; then
            failures="$(( $(daily_failure_count) + 1 ))"
            daily_record "skipped-locked" 75 "${DAILY_PREPARATION_ID}" \
                "${snapshot_tag}" "" "${started_at}" "${started_epoch}" "${failures}"
        else
            write_state "${mode}" "skipped-locked" 75
        fi
        release_locks
        return 75
    fi
    if [[ "${mode}" == daily ]]; then
        # backup.lock is taken before repo.lock. Waiting would hold the
        # scheduler and delay the WAL job past the recovery-point target.
        exec 7>"${LOCK_DIR}/backup.lock"
        if ! flock -s -n 7; then
            log_msg "${mode} skipped: local backup lock was not free"
            failures="$(( $(daily_failure_count) + 1 ))"
            daily_record "skipped-backup-lock" 75 "${DAILY_PREPARATION_ID}" \
                "${snapshot_tag}" "" "${started_at}" "${started_epoch}" "${failures}"
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
        if [[ "${mode}" == daily ]]; then
            failures="$(( $(daily_failure_count) + 1 ))"
            daily_record "skipped-repo-lock" 75 "${DAILY_PREPARATION_ID}" \
                "${snapshot_tag}" "" "${started_at}" "${started_epoch}" "${failures}"
        else
            write_state "${mode}" "skipped-repo-lock" 75
        fi
        release_locks
        return 75
    fi
    prepare_repository
    # --cacert is a parent flag in Restic 0.19.1, so it precedes the subcommand.
    local -a sources=(--exclude '*.pgbackrest.tmp' --tag "${mode}" --host sjv)
    if [[ "${mode}" == daily ]]; then
        sources+=(--tag "${snapshot_tag}" "${BACKUP_ROOT}/pgbackrest" "${DAILY_PREPARATION_DIR}")
    else
        sources+=("${BACKUP_ROOT}/pgbackrest/archive")
    fi
    log_msg "${mode} backup starting"
    snapshot_tmp="$(mktemp)"
    ls_tmp="$(mktemp)"
    if [[ "${mode}" == daily ]]; then
        if snapshot_id="$(daily_snapshot_id "${snapshot_tag}" "${snapshot_tmp}")"; then
            :
        else
            snapshot_rc=$?
        fi
        if [[ -s "${snapshot_tmp}" ]] && [[ "$("${JQ_BIN}" 'length' "${snapshot_tmp}")" -gt 1 ]]; then
            rc=1
        elif [[ "${snapshot_rc}" -eq 0 && -z "${snapshot_id}" && "${rc}" -eq 0 ]]; then
            run_restic --cacert "${CACERT}" backup "${sources[@]}" || rc=$?
            if [[ "${rc}" -eq 0 ]]; then
                snapshot_id="$(daily_snapshot_id "${snapshot_tag}" "${snapshot_tmp}")" || snapshot_rc=$?
                [[ -n "${snapshot_id}" ]] || rc=1
            fi
        fi
        [[ "${snapshot_rc}" -eq 0 ]] || rc="${snapshot_rc}"
        if [[ "${rc}" -eq 0 ]] && ! daily_snapshot_contains_manifest "${snapshot_id}" "${ls_tmp}"; then
            rc=1
        fi
    else
        run_restic --cacert "${CACERT}" backup "${sources[@]}" || rc=$?
        if [[ "${rc}" -eq 0 ]]; then
            run_restic --cacert "${CACERT}" snapshots --latest 1 --tag "${mode}" >/dev/null || rc=$?
        fi
    fi
    rm -f -- "${snapshot_tmp}" "${ls_tmp}"
    if [[ "${rc}" -ne 0 ]]; then
        log_msg "${mode} snapshot check failed"
        if [[ "${mode}" == daily ]]; then
            failures="$(( $(daily_failure_count) + 1 ))"
            daily_record "failed" "${rc}" "${DAILY_PREPARATION_ID}" \
                "${snapshot_tag}" "${snapshot_id}" "${started_at}" "${started_epoch}" "${failures}"
        else
            write_state "${mode}" "failed" "${rc}"
        fi
        release_locks
        return "${rc}"
    fi
    log_msg "${mode} backup finished"
    if [[ "${mode}" == daily ]]; then
        finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        if ! state_write_atomic "${LAST_RESTORABLE}" "$(printf '{"status":"ok","preparation_id":"%s","snapshot_tag":"%s","snapshot_id":"%s","finished_at":"%s"}' \
            "$(json_escape "${DAILY_PREPARATION_ID}")" "$(json_escape "${snapshot_tag}")" \
            "$(json_escape "${snapshot_id}")" "$(json_escape "${finished_at}")")"; then
            failures="$(( $(daily_failure_count) + 1 ))"
            daily_record "failed-evidence" 1 "${DAILY_PREPARATION_ID}" \
                "${snapshot_tag}" "${snapshot_id}" "${started_at}" "${started_epoch}" "${failures}"
            log_msg "daily snapshot succeeded but last-restorable evidence could not be written"
            release_locks
            return 1
        fi
        daily_record "ok" 0 "${DAILY_PREPARATION_ID}" "${snapshot_tag}" \
            "${snapshot_id}" "${started_at}" "${started_epoch}" 0
    else
        write_state "${mode}" "ok" 0
    fi
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
    state_write_atomic "${STATE_DIR}/sjv-backup-daily.date" "$(date +%F)"
}

mark_daily_attempt() {
    state_write_atomic "${STATE_DIR}/sjv-backup-daily.attempt" "$(date +%s)"
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
    state_prepare_dir || {
        log_msg "sjv-backup refused: state directory is unsafe"
        return 1
    }
    mkdir -p "${LOCK_DIR}"
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
