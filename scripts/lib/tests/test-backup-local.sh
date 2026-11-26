#!/usr/bin/env bash
# Offline tests for scripts/backup.sh. Commands are stubs. No database is
# contacted and no Restic repository is used.
# shellcheck disable=SC2016

local_backup_prepare() {
    local base="${TEST_TMP_ROOT}/backup-local/base"
    mkdir -p \
        "${base}/infrastructure-sjv/state" \
        "${base}/infrastructure-sjv/secrets" \
        "${base}/infrastructure-sjv/backup-locks" \
        "${base}/stacks/infrastructure-sjv" \
        "${base}/backups/infrastructure-sjv/pgbackrest" \
        "${base}/backups/infrastructure-sjv/dumps" \
        "${base}/backups/infrastructure-sjv/files" \
        "${base}/backups/infrastructure-sjv/preparations" \
        "${base}/bin" \
        "${base}/stub"
    chmod 700 \
        "${base}/infrastructure-sjv/state" \
        "${base}/infrastructure-sjv/secrets" \
        "${base}/infrastructure-sjv/backup-locks" \
        "${base}/backups/infrastructure-sjv/dumps" \
        "${base}/backups/infrastructure-sjv/files" \
        "${base}/backups/infrastructure-sjv/preparations"
    rm -f -- \
        "${base}/stacks/infrastructure-sjv/.env" \
        "${base}/infrastructure-sjv/secrets/app-kek" \
        "${base}/infrastructure-sjv/secrets/restic-key-password" \
        "${base}/infrastructure-sjv/traefik/acme/acme.json" \
        "${base}/infrastructure-sjv/traefik/users/dashboard.htpasswd" \
        "${base}/infrastructure-sjv/traefik/crowdsec/BOUNCER_KEY_sjv-traefik" \
        "${base}/backups/infrastructure-sjv/dumps"/sjv-*.dump \
        "${base}/backups/infrastructure-sjv/dumps"/.sjv.* \
        "${base}/backups/infrastructure-sjv/files"/* \
        "${base}/infrastructure-sjv/state"/* \
        "${base}/stub"/*
    find "${base}/backups/infrastructure-sjv/preparations" -mindepth 1 -delete
    printf '%s\n' "PG_DB=sjv" "POSTGRES_PASSWORD=fixture-db-password-not-logged" \
        > "${base}/stacks/infrastructure-sjv/.env"
    chmod 600 "${base}/stacks/infrastructure-sjv/.env"
    printf '%s\n' "fixture-restic-key-not-logged" \
        > "${base}/infrastructure-sjv/secrets/restic-key-password"
    chmod 600 "${base}/infrastructure-sjv/secrets/restic-key-password"
    dd if=/dev/zero of="${base}/infrastructure-sjv/secrets/app-kek" bs=32 count=1 status=none
    chmod 600 "${base}/infrastructure-sjv/secrets/app-kek"
    cat > "${base}/bin/pg_isready" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "pg_isready" >> "${STUB_LOG}"
exit "${STUB_READY_RC:-0}"
EOF
    cat > "${base}/bin/pgbackrest" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${STUB_LOG}"
case "${1:-}" in
    info)
        if [[ -f "${STUB_DIR}/backup-made" ]]; then
            printf '%s\n' '{"name":"sjv","backup":[{"type":"full","label":"20261122-120000F"}]}'
            exit 0
        fi
        if [[ ! -f "${STUB_DIR}/stanza" ]]; then
            printf '%s\n' "ERROR: stanza 'sjv' does not exist" >&2
            exit 36
        fi
        printf '%s\n' '{"name":"sjv","backup":[]}'
        ;;
    stanza-create)
        if [[ "${STUB_STANZA_RC:-0}" -ne 0 ]]; then
            exit "${STUB_STANZA_RC}"
        fi
        : > "${STUB_DIR}/stanza"
        ;;
    check)
        exit "${STUB_CHECK_RC:-0}"
        ;;
    backup)
        if [[ "${STUB_BACKUP_RC:-0}" -ne 0 ]]; then
            exit "${STUB_BACKUP_RC}"
        fi
        : > "${STUB_DIR}/backup-made"
        ;;
    *)
        exit 91
        ;;
esac
EOF
    cat > "${base}/bin/pg_dump" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${STUB_LOG}"
if [[ "${STUB_DUMP_RC:-0}" -ne 0 ]]; then
    exit "${STUB_DUMP_RC}"
fi
if [[ "${STUB_DUMP_BODY:-PGDMP}" == "BAD" ]]; then
    printf '%s' "XXXX-not-a-dump"
    exit 0
fi
printf '%s' "PGDMPfixture-dump"
EOF
    cat > "${base}/bin/meter" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${STUB_KEYS:-none}"
EOF
    cat > "${base}/bin/restic-daily" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "restic-daily" >> "${STUB_LOG}"
status="${STUB_RESTIC_STATUS:-ok}"
code="${STUB_RESTIC_RC:-0}"
if [[ "${code}" -ne 0 ]]; then
    status="failed"
fi
printf '{"mode":"daily","status":"%s","exit_code":%s,"finished_at":"2026-11-22T12:05:00Z"}\n' \
    "${status}" "${code}" > "${STUB_STATE}/sjv-backup-daily.json"
if [[ "${code}" -ne 0 || "${status}" != "ok" ]]; then
    exit "${code}"
fi
current="$(<"${STUB_PREPARATIONS}/current")"
files="${STUB_PREPARATIONS}/${current}/files"
dumps="${STUB_PREPARATIONS}/${current}/dumps"
[[ -f "${files}/runtime.env" ]] || exit 3
found=0
for dump in "${dumps}"/sjv-*.dump; do
    [[ -f "${dump}" ]] || continue
    found=1
done
[[ "${found}" -eq 1 ]] || exit 3
exit 0
EOF
    chmod 755 "${base}/bin/pg_isready" "${base}/bin/pgbackrest" "${base}/bin/pg_dump" \
        "${base}/bin/meter" "${base}/bin/restic-daily"
    : > "${base}/stub/log"
    printf '%s\n' "${base}"
}

local_backup_run() {
    local base="$1"
    shift
    t_run env NO_COLOR=1 \
        SJV_TEST_BASE_DIR="${base}" \
        SJV_BACKUP_PG_ISREADY="${base}/bin/pg_isready" \
        SJV_BACKUP_PGBACKREST="${base}/bin/pgbackrest" \
        SJV_BACKUP_PG_DUMP="${base}/bin/pg_dump" \
        SJV_BACKUP_METER_KEYS="${base}/bin/meter" \
        SJV_BACKUP_RESTIC="${base}/bin/restic-daily" \
        STUB_DIR="${base}/stub" \
        STUB_LOG="${base}/stub/log" \
        STUB_PREPARATIONS="${base}/backups/infrastructure-sjv/preparations" \
        STUB_STATE="${base}/infrastructure-sjv/state" \
        "$@" \
        "${REPO_ROOT}/scripts/backup.sh" run
}

local_outputs_hide_fixtures() {
    local status="$1"
    grep -q -F "fixture-db-password-not-logged" "${status}" && return 1
    grep -q -F "fixture-restic-key-not-logged" "${status}" && return 1
    grep -q -F "fixture-db-password-not-logged" <<< "${T_OUT}" && return 1
    grep -q -F "fixture-restic-key-not-logged" <<< "${T_OUT}" && return 1
    return 0
}

local_key_not_copied() {
    local base="$1" secret file current files
    secret="${base}/infrastructure-sjv/secrets/restic-key-password"
    current="$(<"${base}/backups/infrastructure-sjv/preparations/current")"
    files="${base}/backups/infrastructure-sjv/preparations/${current}/files"
    [[ ! -e "${files}/restic-key-password" ]] || return 1
    for file in "${files}"/*; do
        [[ -e "${file}" ]] || continue
        cmp -s -- "${secret}" "${file}" && return 1
    done
    return 0
}

local_current_preparation() {
    local base="$1" id
    [[ -f "${base}/backups/infrastructure-sjv/preparations/current" ]] || return 1
    id="$(<"${base}/backups/infrastructure-sjv/preparations/current")"
    [[ "${id}" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    printf '%s\n' "${base}/backups/infrastructure-sjv/preparations/${id}"
}

test_backup_local_success() {
    print_section "Local backup materials"
    local base status files dumps current dow full_count diff_count
    base="$(local_backup_prepare bl1)"
    local_backup_run "${base}"
    status="${base}/infrastructure-sjv/state/backup.json"
    current="$(<"${base}/backups/infrastructure-sjv/preparations/current")"
    files="${base}/backups/infrastructure-sjv/preparations/${current}/files"
    dumps="${base}/backups/infrastructure-sjv/preparations/${current}/dumps"
    t_check "a complete backup exits 0" test "${T_RC}" -eq 0
    t_check "status records local preparation without running Restic" \
        grep -q '"status":"ok".*"pgbackrest":"ok".*"wal_archive":"ok".*"dump":"ok".*"files":"ok".*"app_kek":"copied".*"restic":"not_run".*"error":""' "${status}"
    t_check "the copied environment matches the source and is mode 600" \
        bash -c 'cmp -s "$1" "$2" && [[ "$(stat -c %a "$2")" == 600 ]]' _ \
            "${base}/stacks/infrastructure-sjv/.env" "${files}/runtime.env"
    t_check "the copied app-kek matches the source and is mode 600" \
        bash -c 'cmp -s "$1" "$2" && [[ "$(stat -c %a "$2")" == 600 && "$(stat -c %s "$2")" == 32 ]]' _ \
            "${base}/infrastructure-sjv/secrets/app-kek" "${files}/app-kek"
    t_check "the preparation marker points to the complete preparation" \
        bash -c '[[ "$1" == "$2" ]] && grep -q "\"status\":\"ready\"" "$1/backup-manifest.json" && [[ "$(stat -c %a "$1/backup-manifest.json")" == 600 ]]' _ \
            "${base}/backups/infrastructure-sjv/preparations/${current}" "${files%/files}"
    t_check "the manifest contains no secret fixture" \
        bash -c '! grep -Eq "fixture-|POSTGRES_PASSWORD|RESTIC_REST_PASSWORD" "$1"' _ \
            "${files%/files}/backup-manifest.json"
    t_check "the published preparation has no temporary manifest" \
        test ! -e "${files%/files}/backup-manifest.json.tmp"
    t_check "the logical dump has the PGDMP header and mode 600" \
        bash -c 'h="$(head -c 5 "$1"/sjv-*.dump)"; [[ "${h}" == PGDMP && "$(stat -c %a "$1"/sjv-*.dump)" == 600 ]]' _ "${dumps}"
    t_check "stdout and status hide fixtures" local_outputs_hide_fixtures "${status}"
    t_check "restic-key-password is not in files" local_key_not_copied "${base}"
    t_check "the first run creates the stanza before the local backup" \
        bash -c 'log="$1"; stanza=$(grep -n "^stanza-create$" "${log}" | head -n 1 | cut -d: -f1); backup=$(grep -n "^backup --type=" "${log}" | head -n 1 | cut -d: -f1); [[ -n "${stanza}" && -n "${backup}" && "${stanza}" -lt "${backup}" ]]' _ \
            "${base}/stub/log"
    dow="$(date -u +%u)"
    local_backup_run "${base}"
    current="$(<"${base}/backups/infrastructure-sjv/preparations/current")"
    files="${base}/backups/infrastructure-sjv/preparations/${current}/files"
    dumps="${base}/backups/infrastructure-sjv/preparations/${current}/dumps"
    t_check "a repeated run exits 0" test "${T_RC}" -eq 0
    t_check "a repeated run keeps the copied files private and complete" \
        bash -c 'cmp -s "$1" "$2" && [[ "$(stat -c %a "$2")" == 600 && "$(stat -c %a "$3")" == 600 ]]' _ \
            "${base}/stacks/infrastructure-sjv/.env" "${files}/runtime.env" "${files}/app-kek"
    full_count="$(grep -c '^backup --type=full$' "${base}/stub/log" || true)"
    diff_count="$(grep -c '^backup --type=diff$' "${base}/stub/log" || true)"
    if [[ "${dow}" == "7" ]]; then
        t_check "Sunday runs stay full backups" \
            bash -c '[[ "$1" == 2 && "$2" == 0 ]]' _ "${full_count}" "${diff_count}"
    else
        t_check "a later weekday run is a differential backup" \
            bash -c '[[ "$1" == 1 && "$2" == 1 ]]' _ "${full_count}" "${diff_count}"
    fi
    t_check "each preparation keeps its own dump" \
        bash -c 'n=0; for f in "$1"/sjv-*.dump; do [[ -f "$f" ]] && n=$((n + 1)); done; [[ "$n" -eq 1 ]]' _ "${dumps}"
    t_check "the repeated run publishes a different preparation" \
        bash -c '[[ "$1" -ge 2 ]]' _ \
            "$(find "${base}/backups/infrastructure-sjv/preparations" -mindepth 1 -maxdepth 1 -type d -name '20*' | wc -l)"
    t_check "stanza-create runs once" \
        bash -c '[[ "$(grep -c "^stanza-create$" "$1")" == 1 ]]' _ "${base}/stub/log"
    cp -- "${files}/runtime.env" "${base}/stub/good-env" || true
    rm -f -- "${base}/stacks/infrastructure-sjv/.env"
    ln -s "${base}/stub/good-env" "${base}/stacks/infrastructure-sjv/.env"
    local_backup_run "${base}"
    t_check "a symlinked environment fails" test "${T_RC}" -ne 0
    t_check "a failed copy leaves the previous environment file intact" \
        cmp -s "${base}/stub/good-env" "${files}/runtime.env"
    t_check "the failed run does not claim success" \
        grep -q '"status":"failed"' "${status}"
}

test_backup_local_failures() {
    print_section "Local backup failures"
    local base status current files dumps
    base="$(local_backup_prepare bl2)"
    local_backup_run "${base}" STUB_READY_RC=1
    status="${base}/infrastructure-sjv/state/backup.json"
    t_check "a missing database fails" test "${T_RC}" -ne 0
    t_check "a missing database does not run pgBackRest" \
        bash -c '! grep -q "^info " "$1" && grep -q "database-missing" "$2"' _ \
            "${base}/stub/log" "${status}"
    t_check "a missing database hides fixtures" local_outputs_hide_fixtures "${status}"

    base="$(local_backup_prepare bl3)"
    local_backup_run "${base}" STUB_BACKUP_RC=1
    status="${base}/infrastructure-sjv/state/backup.json"
    t_check "a failed pgBackRest backup fails" test "${T_RC}" -ne 0
    t_check "a failed pgBackRest backup does not dump or snapshot" \
        bash -c 'grep -q "pgbackrest-failed" "$1" && ! grep -q "restic-daily" "$2" && ! find "$3" -name "sjv-*.dump" -type f -print -quit | grep -q .' _ \
            "${status}" "${base}/stub/log" "${base}/backups/infrastructure-sjv/preparations"

    base="$(local_backup_prepare bl4)"
    local_backup_run "${base}" STUB_CHECK_RC=1
    status="${base}/infrastructure-sjv/state/backup.json"
    t_check "a failed WAL check is not a successful backup" \
        bash -c '[[ "$1" -ne 0 ]] && grep -q "wal-archive-failed" "$2" && ! grep -q "^backup --type=" "$3"' _ \
            "${T_RC}" "${status}" "${base}/stub/log"

    base="$(local_backup_prepare bl5)"
    local_backup_run "${base}" STUB_DUMP_RC=1
    status="${base}/infrastructure-sjv/state/backup.json"
    t_check "a failed pg_dump fails" test "${T_RC}" -ne 0
    t_check "a failed pg_dump does not leave a dump or a snapshot" \
        bash -c 'grep -q "dump-failed" "$1" && ! grep -q "restic-daily" "$2" && ! find "$3" -name "sjv-*.dump" -type f -print -quit | grep -q .' _ \
            "${status}" "${base}/stub/log" "${base}/backups/infrastructure-sjv/preparations"
    t_check "pg_dump is asked for a custom archive without a password argument" \
        bash -c 'grep -qx "\-Fc --no-password --dbname=sjv" "$1" && ! grep -q "fixture-db-password-not-logged" "$1"' _ \
            "${base}/stub/log"

    base="$(local_backup_prepare bl6)"
    local_backup_run "${base}" STUB_DUMP_BODY=BAD
    status="${base}/infrastructure-sjv/state/backup.json"
    t_check "a dump without a PGDMP header fails" test "${T_RC}" -ne 0
    t_check "a damaged dump is not kept" \
        bash -c '! find "$1" -name "sjv-*.dump" -type f -print -quit | grep -q . && ! find "$1" -name ".sjv.*" -type f -print -quit | grep -q . && grep -q "dump-failed" "$2"' _ \
            "${base}/backups/infrastructure-sjv/preparations" "${status}"

    base="$(local_backup_prepare bl7)"
    rm -f -- "${base}/infrastructure-sjv/secrets/app-kek"
    local_backup_run "${base}" STUB_KEYS=present
    status="${base}/infrastructure-sjv/state/backup.json"
    t_check "missing app-kek with encrypted meter keys is incomplete" \
        bash -c '[[ "$1" -eq 2 ]] && grep -q "\"status\":\"incomplete\"" "$2" && grep -q "\"app_kek\":\"missing\"" "$2" && ! find "$3" -path "*/files/app-kek" -print -quit | grep -q .' _ \
            "${T_RC}" "${status}" "${base}/backups/infrastructure-sjv/preparations"
    t_check "an incomplete backup is not recorded as the last success" \
        test ! -e "${base}/infrastructure-sjv/state/backup-last-success.json"
    t_check "an incomplete preparation does not start Restic" \
        bash -c 'grep -q "\"restic\":\"not_run\"" "$1" && ! grep -q "^restic-daily$" "$2"' _ \
            "${status}" "${base}/stub/log"
    t_check "an incomplete backup hides fixtures" local_outputs_hide_fixtures "${status}"

    base="$(local_backup_prepare bl8)"
    rm -f -- "${base}/infrastructure-sjv/secrets/app-kek"
    printf '%s\n' "short-key" > "${base}/infrastructure-sjv/secrets/app-kek"
    chmod 600 "${base}/infrastructure-sjv/secrets/app-kek"
    local_backup_run "${base}"
    status="${base}/infrastructure-sjv/state/backup.json"
    t_check "a short app-kek is a failed backup and is not copied" \
        bash -c '[[ "$1" -ne 0 ]] && grep -q "app-kek-damaged" "$2" && ! find "$3" -path "*/files/app-kek" -print -quit | grep -q .' _ \
            "${T_RC}" "${status}" "${base}/backups/infrastructure-sjv/preparations"

    base="$(local_backup_prepare bl9)"
    local_backup_run "${base}" STUB_RESTIC_RC=1
    status="${base}/infrastructure-sjv/state/backup.json"
    t_check "local preparation succeeds without starting a Restic snapshot" test "${T_RC}" -eq 0
    t_check "local preparation records Restic as not run" \
        grep -q '"restic":"not_run"' "${status}"
    t_check "local preparation does not invoke the Restic stub" \
        bash -c '! grep -q "^restic-daily$" "$1"' _ "${base}/stub/log"

    base="$(local_backup_prepare bl10)"
    local_backup_run "${base}" STUB_RESTIC_STATUS=not-configured STUB_RESTIC_RC=0
    status="${base}/infrastructure-sjv/state/backup.json"
    t_check "a local preparation does not depend on Restic status" \
        bash -c '[[ "$1" -eq 0 ]] && grep -q "\"restic\":\"not_run\"" "$2"' _ "${T_RC}" "${status}"
}

test_backup_preparations() {
    print_section "Atomic backup preparations"
    local base status first second current manifest

    base="$(local_backup_prepare prep1)"
    local_backup_run "${base}"
    first="$(<"${base}/backups/infrastructure-sjv/preparations/current")"
    manifest="${base}/backups/infrastructure-sjv/preparations/${first}/backup-manifest.json"
    t_check "a successful preparation publishes current atomically" \
        bash -c '[[ "$1" == "$2" ]] && [[ -f "$3" ]] && [[ ! -e "$3.tmp" ]]' _ \
            "${first}" "$(basename -- "${first}")" "${manifest}"
    t_check "the published manifest has the ready state" \
        grep -q '"status":"ready"' "${manifest}"

    rm -f -- "${base}/infrastructure-sjv/secrets/app-kek"
    local incomplete_current
    incomplete_current="$(<"${base}/backups/infrastructure-sjv/preparations/current")"
    local_backup_run "${base}" STUB_KEYS=present
    status="${base}/infrastructure-sjv/state/backup.json"
    t_check "missing app-kek after a complete preparation is incomplete" \
        bash -c '[[ "$1" -eq 2 ]] && grep -q "\"status\":\"incomplete\"" "$2"' _ \
            "${T_RC}" "${status}"
    t_check "an incomplete preparation preserves the previous current" \
        test "${incomplete_current}" = "$(<"${base}/backups/infrastructure-sjv/preparations/current")"
    t_check "the previous preparation and ready manifest remain intact" \
        bash -c '[[ -f "$1/backup-manifest.json" ]] && grep -q "\"status\":\"ready\"" "$1/backup-manifest.json"' _ \
            "${base}/backups/infrastructure-sjv/preparations/${incomplete_current}"
    t_check "the incomplete preparation is recorded separately and is not ready" \
        bash -c 'for manifest in "$1"/.*.incomplete/backup-manifest.json; do [[ -f "$manifest" ]] || continue; grep -q "\"status\":\"incomplete\"" "$manifest" && ! grep -q "\"status\":\"ready\"" "$manifest" && exit 0; done; exit 1' _ \
            "${base}/backups/infrastructure-sjv/preparations"
    t_check "the backup lock is released after an incomplete preparation" \
        bash -c 'flock -n -x "$1" true' _ \
            "${base}/infrastructure-sjv/backup-locks/backup.lock"

    printf '%s\n' "broken" > "${base}/infrastructure-sjv/secrets/app-kek"
    chmod 600 "${base}/infrastructure-sjv/secrets/app-kek"
    local_backup_run "${base}"
    second="$(<"${base}/backups/infrastructure-sjv/preparations/current")"
    status="${base}/infrastructure-sjv/state/backup.json"
    t_check "a damaged app-kek is failed" \
        bash -c '[[ "$1" -ne 0 ]] && grep -q "app-kek-damaged" "$2"' _ "${T_RC}" "${status}"
    t_check "a failed preparation does not replace current" test "${first}" = "${second}"
    t_check "a failed preparation does not put secrets in its manifest" \
        bash -c '! find "$1" -name backup-manifest.json -type f -exec grep -E "fixture-|broken|POSTGRES_PASSWORD" {} + >/dev/null 2>&1' _ \
            "${base}/backups/infrastructure-sjv/preparations"

    base="$(local_backup_prepare prep2)"
    local_backup_run "${base}"
    first="$(<"${base}/backups/infrastructure-sjv/preparations/current")"
    local_backup_run "${base}" SJV_BACKUP_TEST_FAIL_AFTER_PREPARATION_RENAME=1
    second="$(<"${base}/backups/infrastructure-sjv/preparations/current")"
    t_check "a failure after directory rename preserves the old current" \
        test "${first}" = "${second}"
    t_check "a renamed but unpublished preparation is recorded as failed" \
        bash -c 'find "$1" -mindepth 1 -maxdepth 1 -type d -name ".*.failed" -print -quit | grep -q .' _ \
            "${base}/backups/infrastructure-sjv/preparations"

    base="$(local_backup_prepare prep3)"
    rm -f -- "${base}/infrastructure-sjv/secrets/app-kek"
    ln -s "${base}/stacks/infrastructure-sjv/.env" \
        "${base}/infrastructure-sjv/secrets/app-kek"
    local_backup_run "${base}"
    status="${base}/infrastructure-sjv/state/backup.json"
    t_check "a symlinked app-kek is rejected" \
        bash -c '[[ "$1" -ne 0 ]] && grep -q "app-kek-damaged" "$2"' _ "${T_RC}" "${status}"

    base="$(local_backup_prepare prep4)"
    printf '%s\n' "not-a-preparation" > "${base}/stub/marker-target"
    ln -s "${base}/stub/marker-target" \
        "${base}/backups/infrastructure-sjv/preparations/current"
    local_backup_run "${base}"
    status="${base}/infrastructure-sjv/state/backup.json"
    t_check "a symlinked current marker is rejected" \
        bash -c '[[ "$1" -ne 0 ]] && grep -q "\"status\":\"failed\"" "$2"' _ "${T_RC}" "${status}"

    base="$(local_backup_prepare prep5)"
    printf '%s\n' "marker-target" > "${base}/stub/marker-target"
    ln -s "${base}/stub/marker-target" \
        "${base}/backups/infrastructure-sjv/preparations/.current.tmp"
    local_backup_run "${base}"
    t_check "an old symlink temporary marker is not used" \
        test -L "${base}/backups/infrastructure-sjv/preparations/.current.tmp"

    base="$(local_backup_prepare prep6)"
    printf '%s\n' "sentinel" > "${base}/backups/infrastructure-sjv/preparations/.current.tmp"
    local_backup_run "${base}"
    t_check "an old regular temporary marker is not used" \
        bash -c '[[ "$(cat "$1")" == sentinel ]]' _ \
            "${base}/backups/infrastructure-sjv/preparations/.current.tmp"

    base="$(local_backup_prepare prep7)"
    local_backup_run "${base}"
    first="$(<"${base}/backups/infrastructure-sjv/preparations/current")"
    local_backup_run "${base}" SJV_BACKUP_TEST_FAIL_MARKER_PUBLISH=1
    second="$(<"${base}/backups/infrastructure-sjv/preparations/current")"
    t_check "a marker publication error preserves current" test "${first}" = "${second}"
    t_check "a marker publication error cleans its unique temporary file" \
        bash -c '! find "$1" -mindepth 1 -maxdepth 1 -name ".current.??????" -type f -print -quit | grep -q .' _ \
            "${base}/backups/infrastructure-sjv/preparations"

    base="$(local_backup_prepare prep8)"
    local_backup_run "${base}" SJV_BACKUP_TEST_MANIFEST_VALUES=1
    current="$(<"${base}/backups/infrastructure-sjv/preparations/current")"
    manifest="${base}/backups/infrastructure-sjv/preparations/${current}/backup-manifest.json"
    t_check "manifest with quotes, backslashes and newlines is valid JSON" \
        python3 -c 'import json, sys; d=json.load(open(sys.argv[1])); v=d["pgbackrest_label"]; assert v.startswith("label\"\\\n"); assert [ord(c) for c in v[8:]] == list(range(1, 32)); assert d["pgbackrest_type"] == "type\"\\\n"; assert d["dump_file"] == "dump\"\\\n"' \
            "${manifest}"

    base="$(local_backup_prepare prep9)"
    chmod 644 "${base}/infrastructure-sjv/secrets/app-kek"
    local_backup_run "${base}"
    status="${base}/infrastructure-sjv/state/backup.json"
    t_check "an app-kek with open permissions is rejected" \
        bash -c '[[ "$1" -ne 0 ]] && grep -q "app-kek-damaged" "$2"' _ "${T_RC}" "${status}"

    base="$(local_backup_prepare prep10)"
    local_backup_run "${base}"
    first="$(<"${base}/backups/infrastructure-sjv/preparations/current")"
    local_backup_run "${base}" SJV_BACKUP_TEST_FAIL_MARKER_MV=1
    second="$(<"${base}/backups/infrastructure-sjv/preparations/current")"
    t_check "a real marker mv failure preserves current" test "${first}" = "${second}"
    t_check "a real marker mv failure removes the temporary marker" \
        bash -c '! find "$1" -mindepth 1 -maxdepth 1 -name ".current.??????" -type f -print -quit | grep -q .' _ \
            "${base}/backups/infrastructure-sjv/preparations"
    t_check "a real marker mv failure does not publish the new preparation" \
        bash -c '! find "$1" -mindepth 1 -maxdepth 1 -type d -name "20*" -newer "$2" -print -quit | grep -q .' _ \
            "${base}/backups/infrastructure-sjv/preparations" \
            "${base}/backups/infrastructure-sjv/preparations/current"

    base="$(local_backup_prepare prep11)"
    find "${base}/backups/infrastructure-sjv/preparations" -mindepth 1 -delete
    rmdir -- "${base}/backups/infrastructure-sjv/preparations"
    ln -s "${base}/stub" "${base}/backups/infrastructure-sjv/preparations"
    local_backup_run "${base}"
    t_check "a symlinked preparations directory is rejected" \
        bash -c '[[ "$1" -ne 0 ]] && [[ -L "$2" ]]' _ "${T_RC}" \
            "${base}/backups/infrastructure-sjv/preparations"
    rm -f -- "${base}/backups/infrastructure-sjv/preparations"
    mkdir -m 700 "${base}/backups/infrastructure-sjv/preparations"

    base="$(local_backup_prepare prep12)"
    chmod 755 "${base}/backups/infrastructure-sjv/preparations"
    local_backup_run "${base}"
    t_check "preparations mode is tightened to 700" \
        test "$(stat -c %a "${base}/backups/infrastructure-sjv/preparations")" = 700

    for optional in acme htpasswd bouncer; do
        base="$(local_backup_prepare "optional-${optional}")"
        case "${optional}" in
            acme) source="${base}/infrastructure-sjv/traefik/acme/acme.json" ;;
            htpasswd) source="${base}/infrastructure-sjv/traefik/users/dashboard.htpasswd" ;;
            bouncer) source="${base}/infrastructure-sjv/traefik/crowdsec/BOUNCER_KEY_sjv-traefik" ;;
        esac
        mkdir -p -- "${source%/*}"
        ln -s "${base}/stacks/infrastructure-sjv/.env" "${source}"
        local_backup_run "${base}"
        t_check "a symlinked optional ${optional} source is rejected" \
            bash -c '[[ "$1" -ne 0 ]] && grep -q "files-damaged" "$2"' _ "${T_RC}" \
                "${base}/infrastructure-sjv/state/backup.json"
    done
}

test_backup_local_guards() {
    print_section "Local backup guards"
    local base status lock holder
    base="$(local_backup_prepare bl11)"
    lock="${base}/infrastructure-sjv/backup-locks/backup.lock"
    : > "${lock}"
    set -m
    flock -x "${lock}" sleep 30 &
    holder=$!
    set +m
    local attempt=0
    while flock -n -x "${lock}" true 2>/dev/null; do
        attempt=$((attempt + 1))
        if [[ "${attempt}" -ge 50 ]]; then
            break
        fi
        sleep 0.05
    done
    local_backup_run "${base}"
    kill -TERM -"${holder}" 2>/dev/null || kill -TERM "${holder}" 2>/dev/null || true
    wait "${holder}" 2>/dev/null || true
    status="${base}/infrastructure-sjv/state/backup.json"
    t_check "a busy backup lock is not a successful backup" \
        bash -c '[[ "$1" -ne 0 ]] && grep -q "lock-busy" "$2" && ! grep -q "^pg_isready$" "$3"' _ \
            "${T_RC}" "${status}" "${base}/stub/log"

    t_run env -u SJV_TEST_BASE_DIR NO_COLOR=1 "${REPO_ROOT}/scripts/backup.sh" --help
    t_check "backup.sh help exits 0" test "${T_RC}" -eq 0
    t_run env -u SJV_TEST_BASE_DIR NO_COLOR=1 "${REPO_ROOT}/scripts/backup.sh" --bogus
    t_check "backup.sh rejects an unknown option" \
        bash -c '[[ "$1" -ne 0 ]] && [[ "$2" == *"Unknown option"* ]]' _ "${T_RC}" "${T_OUT}"

    local body
    body="$(awk '/^docker_postgres_exec\(\)/,/^}/' "${REPO_ROOT}/scripts/lib/deploy/docker.sh")"
    t_check "postgres exec accepts only the fixed backup commands" \
        bash -c 'printf "%s\n" "$1" | grep -q "pg_isready" && printf "%s\n" "$1" | grep -q -- "--no-password" && ! printf "%s\n" "$1" | grep -q "PGPASSWORD"' _ "${body}"
    t_check "postgresql stays off the general container allow-list" \
        bash -c 'awk "/^docker_require_service\\(\\)/,/^}/" "$1" | grep -q "sjv-traefik|sjv-crowdsec|sjv-backup" && ! awk "/^docker_require_service\\(\\)/,/^}/" "$1" | grep -q "sjv-postgresql"' _ \
            "${REPO_ROOT}/scripts/lib/deploy/docker.sh"
    t_check "compose does not mount app-kek into the Restic service" \
        bash -c '! grep -q "app-kek" "$1"' _ "${REPO_ROOT}/compose/30-backup.yml"
    t_check "compose does not give PostgreSQL a new dumps or files mount" \
        bash -c '! grep -Eq "/dumps|/files|app-kek" "$1"' _ "${REPO_ROOT}/compose/40-postgresql.yml"
}

run_backup_local_tests() {
    print_header "Local backup creation"
    test_backup_local_success
    test_backup_local_failures
    test_backup_preparations
    test_backup_local_guards
}
