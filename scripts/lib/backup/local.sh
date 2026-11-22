#!/usr/bin/env bash
# Local backup materials for one Restic daily snapshot.
# pgBackRest and pg_dump run in the PostgreSQL container. This file does not
# call expire, forget, or prune, and it does not copy restic-key-password.

DUMPS_DIR="${BACKUP_LOCAL_DIR}/dumps"
FILES_DIR="${BACKUP_LOCAL_DIR}/files"
LOCK_FILE="${DATA_DIR}/backup-locks/backup.lock"
STATUS_FILE="${STATE_DIR}/backup.json"
LAST_SUCCESS_FILE="${STATE_DIR}/backup-last-success.json"
LAST_RESTIC_FILE="${STATE_DIR}/backup-last-restic.json"

BACKUP_FINALIZED=0
BACKUP_RESULT="failed"
BACKUP_EXIT=1
BACKUP_FINISHED_AT=""
BACKUP_PGBR="not_run"
BACKUP_LABEL=""
BACKUP_TYPE=""
BACKUP_WAL="not_run"
BACKUP_DUMP="not_run"
BACKUP_DUMP_FILE=""
BACKUP_FILES="not_run"
BACKUP_KEK="not_run"
BACKUP_RESTIC="not_run"
BACKUP_ERROR=""
LAST_SUCCESS_AT=""
LAST_RESTIC_AT=""
DUMP_TMP=""
INFO_FILE=""
PGBR_ERR=""
INCOMPLETE=0
METER_STATE=""

backup_timestamp() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

backup_allow_error() {
    case "$1" in
        ""|database-missing|stanza-create-failed|wal-archive-failed|pgbackrest-failed|dump-failed|env-missing|files-damaged|app-kek-damaged|meter-state-unreadable|lock-busy|restic-failed|unexpected|app-kek-missing)
            printf '%s\n' "$1"
            ;;
        *)
            printf '%s\n' "unexpected"
            ;;
    esac
}

backup_allow_simple() {
    case "$1" in
        ok|incomplete|failed|not_run|copied|missing|not_required|damaged|absent|full|diff)
            printf '%s\n' "$1"
            ;;
        *)
            printf '%s\n' "failed"
            ;;
    esac
}

backup_read_time_file() {
    local path="$1" key="$2" line=""
    [[ -f "${path}" && ! -L "${path}" ]] || return 0
    IFS= read -r line < "${path}" || return 0
    [[ "${line}" =~ \"${key}\":\"([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)\" ]] || return 0
    printf '%s\n' "${BASH_REMATCH[1]}"
}

backup_load_history() {
    local value=""
    LAST_SUCCESS_AT=""
    LAST_RESTIC_AT=""
    value="$(backup_read_time_file "${LAST_SUCCESS_FILE}" finished_at || true)"
    LAST_SUCCESS_AT="${value}"
    value="$(backup_read_time_file "${LAST_RESTIC_FILE}" restic_finished_at || true)"
    LAST_RESTIC_AT="${value}"
}

backup_write_json() {
    local path="$1" body="$2" tmp
    [[ -d "${STATE_DIR}" ]] || mkdir -m 700 "${STATE_DIR}"
    tmp="$(mktemp "${STATE_DIR}/.status.XXXXXX")"
    chmod 600 "${tmp}"
    printf '%s\n' "${body}" > "${tmp}"
    mv -f "${tmp}" "${path}"
    chmod 600 "${path}"
}

write_backup_status() {
    local now error result pgbr wal dump files kek restic label dump_file btype
    local success_at restic_at
    now="${BACKUP_FINISHED_AT}"
    [[ -n "${now}" ]] || now="$(backup_timestamp)"
    error="$(backup_allow_error "${BACKUP_ERROR}")"
    result="$(backup_allow_simple "${BACKUP_RESULT}")"
    pgbr="$(backup_allow_simple "${BACKUP_PGBR}")"
    wal="$(backup_allow_simple "${BACKUP_WAL}")"
    dump="$(backup_allow_simple "${BACKUP_DUMP}")"
    files="$(backup_allow_simple "${BACKUP_FILES}")"
    kek="$(backup_allow_simple "${BACKUP_KEK}")"
    restic="$(backup_allow_simple "${BACKUP_RESTIC}")"
    btype="$(backup_allow_simple "${BACKUP_TYPE}")"
    [[ "${btype}" == full || "${btype}" == diff ]] || btype=""
    label=""
    if [[ "${BACKUP_LABEL}" =~ ^[0-9]{8}-[0-9]{6}F(_[0-9]{8}-[0-9]{6}D)?$ ]]; then
        label="${BACKUP_LABEL}"
    fi
    dump_file=""
    if [[ "${BACKUP_DUMP_FILE}" =~ ^sjv-[0-9]{8}T[0-9]{6}Z(-[0-9]+)?\.dump$ ]]; then
        dump_file="${BACKUP_DUMP_FILE}"
    fi
    success_at=""
    if [[ "${LAST_SUCCESS_AT}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
        success_at="${LAST_SUCCESS_AT}"
    fi
    restic_at=""
    if [[ "${LAST_RESTIC_AT}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
        restic_at="${LAST_RESTIC_AT}"
    fi
    backup_write_json "${STATUS_FILE}" \
        "{\"status\":\"${result}\",\"exit_code\":${BACKUP_EXIT},\"finished_at\":\"${now}\",\"last_success_at\":\"${success_at}\",\"restic_finished_at\":\"${restic_at}\",\"pgbackrest\":\"${pgbr}\",\"pgbackrest_label\":\"${label}\",\"pgbackrest_type\":\"${btype}\",\"wal_archive\":\"${wal}\",\"dump\":\"${dump}\",\"dump_file\":\"${dump_file}\",\"files\":\"${files}\",\"app_kek\":\"${kek}\",\"restic\":\"${restic}\",\"error\":\"${error}\"}"
}

backup_finalize_exit() {
    local code="$1"
    if [[ "${BACKUP_FINALIZED}" -eq 1 ]]; then
        return 0
    fi
    BACKUP_RESULT="failed"
    BACKUP_EXIT=1
    if [[ -z "${BACKUP_ERROR}" ]]; then
        BACKUP_ERROR="unexpected"
    fi
    write_backup_status || true
    backup_cleanup_temps || true
    if [[ "${code}" -eq 0 ]]; then
        exit 1
    fi
}

backup_cleanup_temps() {
    [[ -z "${DUMP_TMP}" ]] || rm -f -- "${DUMP_TMP}"
    [[ -z "${INFO_FILE}" ]] || rm -f -- "${INFO_FILE}"
    [[ -z "${PGBR_ERR}" ]] || rm -f -- "${PGBR_ERR}"
    DUMP_TMP=""
}

finish_failed() {
    BACKUP_RESULT="failed"
    BACKUP_EXIT=1
    BACKUP_FINISHED_AT="$(backup_timestamp)"
    write_backup_status
    BACKUP_FINALIZED=1
    backup_cleanup_temps
    fail "Backup failed (${BACKUP_ERROR})."
}

finish_incomplete() {
    BACKUP_RESULT="incomplete"
    BACKUP_EXIT=2
    BACKUP_ERROR="app-kek-missing"
    BACKUP_FINISHED_AT="$(backup_timestamp)"
    write_backup_status
    BACKUP_FINALIZED=1
    backup_cleanup_temps
    error "Backup is incomplete: encrypted meter keys exist and app-kek was not copied."
    exit 2
}

finish_ok() {
    local now restic_body success_body
    now="$(backup_timestamp)"
    BACKUP_FINISHED_AT="${now}"
    LAST_SUCCESS_AT="${now}"
    BACKUP_RESULT="ok"
    BACKUP_EXIT=0
    BACKUP_ERROR=""
    write_backup_status
    restic_body="{\"restic_finished_at\":\"${LAST_RESTIC_AT}\"}"
    success_body="{\"finished_at\":\"${now}\",\"restic_finished_at\":\"${LAST_RESTIC_AT}\",\"pgbackrest_label\":\"${BACKUP_LABEL}\",\"dump_file\":\"${BACKUP_DUMP_FILE}\"}"
    backup_write_json "${LAST_RESTIC_FILE}" "${restic_body}"
    backup_write_json "${LAST_SUCCESS_FILE}" "${success_body}"
    BACKUP_FINALIZED=1
    backup_cleanup_temps
    ok "Backup completed."
    exit 0
}

invoke_database() {
    local tool="$1" bin=""
    shift
    if [[ "${SJV_TEST_MODE}" -eq 1 ]]; then
        case "${tool}" in
            pg_isready) bin="${SJV_BACKUP_PG_ISREADY:-}" ;;
            pgbackrest) bin="${SJV_BACKUP_PGBACKREST:-}" ;;
            pg_dump) bin="${SJV_BACKUP_PG_DUMP:-}" ;;
            meter) bin="${SJV_BACKUP_METER_KEYS:-}" ;;
            *) fail "Unknown database tool." ;;
        esac
        [[ -n "${bin}" && -x "${bin}" && ! -L "${bin}" ]] || fail "Test backup command is not executable."
        "${bin}" "$@"
        return
    fi
    case "${tool}" in
        meter) docker_postgres_exec psql ;;
        *) docker_postgres_exec "${tool}" "$@" ;;
    esac
}

invoke_restic_daily() {
    local bin=""
    if [[ "${SJV_TEST_MODE}" -eq 1 ]]; then
        bin="${SJV_BACKUP_RESTIC:-}"
        [[ -n "${bin}" && -x "${bin}" && ! -L "${bin}" ]] || fail "Test backup command is not executable."
        "${bin}"
        return
    fi
    docker_compose_backup_daily
}

backup_prepare_dirs() {
    ensure_dir "${DATA_DIR}/backup-locks" 700
    ensure_dir "${STATE_DIR}" 700
    ensure_dir "${DUMPS_DIR}" 700
    ensure_dir "${FILES_DIR}" 700
    [[ -d "${BACKUP_LOCAL_DIR}/pgbackrest" && ! -L "${BACKUP_LOCAL_DIR}/pgbackrest" ]] \
        || fail "pgBackRest repository directory is missing."
}

backup_hold_lock() {
    [[ ! -L "${LOCK_FILE}" ]] || fail "Lock file ${LOCK_FILE} is a symlink."
    (umask 077 && : >> "${LOCK_FILE}")
    exec 7>>"${LOCK_FILE}"
    if ! flock -n 7; then
        BACKUP_ERROR="lock-busy"
        finish_failed
    fi
}

backup_release_lock() {
    exec 7>&- || true
}

choose_backup_type() {
    local info_file="$1" dow
    dow="$(date -u +%u)"
    if [[ "${dow}" == "7" ]]; then
        printf '%s\n' "full"
        return 0
    fi
    if [[ -s "${info_file}" ]] && grep -q '"type"[[:space:]]*:[[:space:]]*"full"' "${info_file}"; then
        printf '%s\n' "diff"
        return 0
    fi
    printf '%s\n' "full"
}

stanza_is_missing() {
    local err_file="$1"
    [[ -f "${err_file}" ]] || return 1
    grep -q "does not exist" "${err_file}" || return 1
    grep -q "stanza" "${err_file}"
}

read_backup_label() {
    local info_file="$1" label=""
    label="$(grep -oE '[0-9]{8}-[0-9]{6}F(_[0-9]{8}-[0-9]{6}D)?' "${info_file}" | tail -n 1 || true)"
    [[ "${label}" =~ ^[0-9]{8}-[0-9]{6}F(_[0-9]{8}-[0-9]{6}D)?$ ]] || return 1
    printf '%s\n' "${label}"
}

run_pgbackrest() {
    local info_rc=0 label=""
    INFO_FILE="$(mktemp)"
    PGBR_ERR="$(mktemp)"
    chmod 600 "${INFO_FILE}" "${PGBR_ERR}"
    if ! invoke_database pgbackrest info --output=json >"${INFO_FILE}" 2>"${PGBR_ERR}"; then
        info_rc=1
    fi
    if [[ "${info_rc}" -ne 0 ]]; then
        if stanza_is_missing "${PGBR_ERR}"; then
            if ! invoke_database pgbackrest stanza-create; then
                BACKUP_PGBR="failed"
                BACKUP_ERROR="stanza-create-failed"
                finish_failed
            fi
            : > "${INFO_FILE}"
        else
            BACKUP_PGBR="failed"
            BACKUP_ERROR="pgbackrest-failed"
            finish_failed
        fi
    fi
    if ! invoke_database pgbackrest check; then
        BACKUP_PGBR="failed"
        BACKUP_WAL="failed"
        BACKUP_ERROR="wal-archive-failed"
        finish_failed
    fi
    BACKUP_WAL="ok"
    BACKUP_TYPE="$(choose_backup_type "${INFO_FILE}")"
    if ! invoke_database pgbackrest backup "--type=${BACKUP_TYPE}"; then
        BACKUP_PGBR="failed"
        BACKUP_ERROR="pgbackrest-failed"
        finish_failed
    fi
    if ! invoke_database pgbackrest info --output=json >"${INFO_FILE}" 2>"${PGBR_ERR}"; then
        BACKUP_PGBR="failed"
        BACKUP_ERROR="pgbackrest-failed"
        finish_failed
    fi
    if ! label="$(read_backup_label "${INFO_FILE}")"; then
        BACKUP_PGBR="failed"
        BACKUP_ERROR="pgbackrest-failed"
        finish_failed
    fi
    BACKUP_LABEL="${label}"
    BACKUP_PGBR="ok"
    rm -f -- "${INFO_FILE}" "${PGBR_ERR}"
    INFO_FILE=""
    PGBR_ERR=""
    info "pgBackRest backup ${BACKUP_LABEL} (${BACKUP_TYPE})."
}

run_logical_dump() {
    local header="" size=0 stamp="" name="" n=0
    DUMP_TMP="$(mktemp "${DUMPS_DIR}/.sjv.XXXXXX")"
    chmod 600 "${DUMP_TMP}"
    if ! invoke_database pg_dump -Fc --no-password --dbname=sjv >"${DUMP_TMP}"; then
        rm -f -- "${DUMP_TMP}"
        DUMP_TMP=""
        BACKUP_DUMP="failed"
        BACKUP_ERROR="dump-failed"
        finish_failed
    fi
    header="$(head -c 5 -- "${DUMP_TMP}" || true)"
    size="$(stat -c '%s' "${DUMP_TMP}")"
    if [[ "${header}" != "PGDMP" || "${size}" -le 5 ]]; then
        rm -f -- "${DUMP_TMP}"
        DUMP_TMP=""
        BACKUP_DUMP="failed"
        BACKUP_ERROR="dump-failed"
        finish_failed
    fi
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    name="sjv-${stamp}.dump"
    while [[ -e "${DUMPS_DIR}/${name}" ]]; do
        n=$((n + 1))
        if [[ "${n}" -ge 100 ]]; then
            rm -f -- "${DUMP_TMP}"
            DUMP_TMP=""
            BACKUP_DUMP="failed"
            BACKUP_ERROR="dump-failed"
            finish_failed
        fi
        name="sjv-${stamp}-${n}.dump"
    done
    mv -n -- "${DUMP_TMP}" "${DUMPS_DIR}/${name}"
    DUMP_TMP=""
    [[ -f "${DUMPS_DIR}/${name}" && ! -L "${DUMPS_DIR}/${name}" ]] || {
        BACKUP_DUMP="failed"
        BACKUP_ERROR="dump-failed"
        finish_failed
    }
    chmod 600 "${DUMPS_DIR}/${name}"
    BACKUP_DUMP="ok"
    BACKUP_DUMP_FILE="${name}"
    info "Logical dump stored."
}

copy_private() {
    local src="$1" dest="$2" min_size="$3" max_size="$4" size="" tmp="" mode=""
    [[ "$(basename -- "${src}")" != "restic-key-password" ]] || return 1
    [[ "$(basename -- "${dest}")" != "restic-key-password" ]] || return 1
    [[ "${src}" != "${BACKUP_LOCAL_DIR}" && "${src}" != "${BACKUP_LOCAL_DIR}"/* ]] || return 1
    [[ "${dest}" == "${FILES_DIR}/"* ]] || return 1
    [[ -f "${src}" && ! -L "${src}" ]] || return 1
    size="$(stat -c '%s' "${src}")"
    [[ "${size}" -ge "${min_size}" ]] || return 1
    if [[ "${max_size}" -gt 0 && "${size}" -ne "${max_size}" ]]; then
        return 1
    fi
    tmp="$(mktemp "${FILES_DIR}/.partial.XXXXXX")"
    chmod 600 "${tmp}"
    if ! cp -- "${src}" "${tmp}"; then
        rm -f -- "${tmp}"
        return 1
    fi
    chmod 600 "${tmp}"
    if ! cmp -s -- "${src}" "${tmp}"; then
        rm -f -- "${tmp}"
        return 1
    fi
    mode="$(stat -c '%a' "${tmp}")"
    if [[ "${mode}" != "600" ]]; then
        rm -f -- "${tmp}"
        return 1
    fi
    mv -f -- "${tmp}" "${dest}"
    [[ -f "${dest}" && ! -L "${dest}" && "$(stat -c '%a' "${dest}")" == "600" ]]
}

copy_optional() {
    local src="$1" dest="$2"
    if [[ ! -e "${src}" && ! -L "${src}" ]]; then
        return 0
    fi
    if [[ -L "${src}" || ! -f "${src}" ]]; then
        return 1
    fi
    copy_private "${src}" "${dest}" 1 0
}

read_meter_key_state() {
    local word=""
    METER_STATE=""
    if ! word="$(invoke_database meter)"; then
        return 1
    fi
    case "${word}" in
        present|none|absent)
            METER_STATE="${word}"
            ;;
        *)
            return 1
            ;;
    esac
}

copy_recovery_files() {
    local state=""
    if [[ -L "${ENV_FILE}" || ! -f "${ENV_FILE}" ]]; then
        BACKUP_FILES="failed"
        if [[ -e "${ENV_FILE}" || -L "${ENV_FILE}" ]]; then
            BACKUP_ERROR="files-damaged"
        else
            BACKUP_ERROR="env-missing"
        fi
        finish_failed
    fi
    if ! copy_private "${ENV_FILE}" "${FILES_DIR}/runtime.env" 1 0; then
        BACKUP_FILES="failed"
        BACKUP_ERROR="files-damaged"
        finish_failed
    fi
    if [[ -e "${APP_KEK_FILE}" || -L "${APP_KEK_FILE}" ]]; then
        if [[ -L "${APP_KEK_FILE}" || ! -f "${APP_KEK_FILE}" ]] \
            || ! copy_private "${APP_KEK_FILE}" "${FILES_DIR}/app-kek" 32 32; then
            BACKUP_FILES="failed"
            BACKUP_KEK="damaged"
            BACKUP_ERROR="app-kek-damaged"
            finish_failed
        fi
        BACKUP_KEK="copied"
    else
        if ! read_meter_key_state; then
            BACKUP_FILES="failed"
            BACKUP_ERROR="meter-state-unreadable"
            finish_failed
        fi
        state="${METER_STATE}"
        if [[ "${state}" == "present" ]]; then
            BACKUP_KEK="missing"
            INCOMPLETE=1
        else
            BACKUP_KEK="not_required"
        fi
    fi
    if ! copy_optional "${ACME_FILE}" "${FILES_DIR}/acme.json"; then
        BACKUP_FILES="failed"
        BACKUP_ERROR="files-damaged"
        finish_failed
    fi
    if ! copy_optional "${HTPASSWD_FILE}" "${FILES_DIR}/dashboard.htpasswd"; then
        BACKUP_FILES="failed"
        BACKUP_ERROR="files-damaged"
        finish_failed
    fi
    if ! copy_optional "${BOUNCER_KEY_FILE}" "${FILES_DIR}/crowdsec-bouncer-key"; then
        BACKUP_FILES="failed"
        BACKUP_ERROR="files-damaged"
        finish_failed
    fi
    if [[ "${INCOMPLETE}" -eq 1 ]]; then
        BACKUP_FILES="incomplete"
    else
        BACKUP_FILES="ok"
    fi
    info "Recovery files copied."
}

confirm_restic_snapshot() {
    local path="${STATE_DIR}/sjv-backup-daily.json" line="" rc="$1"
    if [[ "${rc}" -ne 0 ]]; then
        BACKUP_RESTIC="failed"
        BACKUP_ERROR="restic-failed"
        finish_failed
    fi
    [[ -f "${path}" && ! -L "${path}" ]] || {
        BACKUP_RESTIC="failed"
        BACKUP_ERROR="restic-failed"
        finish_failed
    }
    IFS= read -r line < "${path}" || {
        BACKUP_RESTIC="failed"
        BACKUP_ERROR="restic-failed"
        finish_failed
    }
    [[ "${line}" =~ \"status\":\"ok\" ]] || {
        BACKUP_RESTIC="failed"
        BACKUP_ERROR="restic-failed"
        finish_failed
    }
    [[ "${line}" =~ \"finished_at\":\"([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)\" ]] || {
        BACKUP_RESTIC="failed"
        BACKUP_ERROR="restic-failed"
        finish_failed
    }
    LAST_RESTIC_AT="${BASH_REMATCH[1]}"
    backup_write_json "${LAST_RESTIC_FILE}" "{\"restic_finished_at\":\"${LAST_RESTIC_AT}\"}"
    BACKUP_RESTIC="ok"
    info "Restic daily snapshot confirmed."
}

backup_run_main() {
    local restic_rc=0
    umask 077
    trap 'backup_finalize_exit "$?"' EXIT
    backup_prepare_dirs
    backup_load_history
    backup_hold_lock
    if ! invoke_database pg_isready; then
        BACKUP_ERROR="database-missing"
        finish_failed
    fi
    run_pgbackrest
    run_logical_dump
    copy_recovery_files
    backup_release_lock
    invoke_restic_daily || restic_rc=$?
    confirm_restic_snapshot "${restic_rc}"
    if [[ "${INCOMPLETE}" -eq 1 ]]; then
        finish_incomplete
    fi
    finish_ok
}

backup_show_status() {
    local path="${STATUS_FILE}" line="" code=""
    [[ -f "${path}" && ! -L "${path}" ]] || fail "No backup status has been recorded."
    IFS= read -r line < "${path}" || fail "No backup status has been recorded."
    printf '%s\n' "${line}"
    if [[ "${line}" =~ \"exit_code\":([0-9]+) ]]; then
        code="${BASH_REMATCH[1]}"
    else
        code=1
    fi
    exit "${code}"
}
