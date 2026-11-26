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
        "${root}/backup/preparations/fixture-preparation/dumps" \
        "${root}/backup/preparations/fixture-preparation/files" "${root}/certs" "${root}/run"
    chmod 700 "${root}/state"
    printf '%s\n' "${secret}" > "${root}/key"
    chmod 600 "${root}/key"
    printf '%s\n' "fixture-certificate" > "${root}/certs/rest-server.crt"
    chmod 644 "${root}/certs/rest-server.crt"
    printf '%s\n' "PGDMPfixture-dump" \
        > "${root}/backup/preparations/fixture-preparation/dumps/sjv-20261126T120000Z.dump"
    printf '%s\n' "PG_DB=sjv" > "${root}/backup/preparations/fixture-preparation/files/runtime.env"
    chmod 600 \
        "${root}/backup/preparations/fixture-preparation/dumps/sjv-20261126T120000Z.dump" \
        "${root}/backup/preparations/fixture-preparation/files/runtime.env"
    printf '%s\n' "fixture-preparation" \
        > "${root}/backup/preparations/current"
    chmod 600 "${root}/backup/preparations/current"
    cat > "${root}/backup/preparations/fixture-preparation/backup-manifest.json" <<'EOF'
{"schema":1,"preparation_id":"fixture-preparation","created_at":"2026-11-26T12:00:00Z","status":"ready","pgbackrest":"ok","pgbackrest_label":"20261126-120000F","pgbackrest_type":"full","wal_archive":"ok","pg_dump":"ok","runtime_config":"ok","app_kek":"not_required","dump_file":"sjv-20261126T120000Z.dump"}
EOF
    chmod 600 "${root}/backup/preparations/fixture-preparation/backup-manifest.json"
    cat > "${root}/bin/jq-stub" <<'EOF'
#!/usr/bin/env python3
import json
import sys

args = sys.argv[1:]
if "-s" in args:
    path = args[-1]
    values = [json.loads(line) for line in open(path) if line.strip()]
    paths = {(item.get("path") or "") for item in values}
    def arg(name):
        return args[args.index(name) + 2]
    root = arg("--arg") if "--arg" in args else ""
    dump = args[args.index("--arg") + 3] if "--arg" in args else ""
    # The production jq expression passes named pairs in this order:
    # root, dump, app_kek, acme, htpasswd, bouncer.
    pairs = {}
    for index, item in enumerate(args):
        if item == "--arg" and index + 2 < len(args):
            pairs[args[index + 1]] = args[index + 2]
    root = pairs.get("root", root)
    dump = pairs.get("dump", dump)
    required = {
        root + "/backup-manifest.json",
        root + "/dumps/" + dump,
        root + "/files/runtime.env",
    }
    if pairs.get("app_kek") == "copied":
        required.add(root + "/files/app-kek")
    if pairs.get("acme") == "copied":
        required.add(root + "/files/acme.json")
    if pairs.get("htpasswd") == "copied":
        required.add(root + "/files/dashboard.htpasswd")
    if pairs.get("bouncer") == "copied":
        required.add(root + "/files/crowdsec-bouncer-key")
    if required <= paths:
        sys.exit(0)
    sys.exit(1)
path = args[-1]
if args and args[0] == "length":
    print(len(json.load(open(path))))
    sys.exit(0)
if ".dump_file" in args:
    print(json.load(open(path))["dump_file"])
    sys.exit(0)
if args and args[0] == "-r" and len(args) > 1 and args[1].split()[0] in (
        ".acme", ".dashboard_htpasswd", ".crowdsec_bouncer_key"):
    key = args[1].split()[0].lstrip(".")
    value = json.load(open(path)).get(key)
    print(value if value is not None else "absent")
    sys.exit(0)
if ".[0].id" in args:
    print(json.load(open(path))[0]["id"])
    sys.exit(0)
if "--arg" in args:
    value = json.load(open(path))
    expected = args[args.index("--arg") + 2]
    sys.exit(0 if value.get("schema") == 1
              and value.get("preparation_id") == expected
              and value.get("status") == "ready"
              and value.get("pgbackrest") == "ok"
              and value.get("pg_dump") == "ok"
              and value.get("runtime_config") == "ok"
              and value.get("wal_archive") == "ok"
              and value.get("app_kek") in ("copied", "not_required")
              and value.get("acme", "absent") in ("copied", "absent")
              and value.get("dashboard_htpasswd", "absent") in ("copied", "absent")
              and value.get("crowdsec_bouncer_key", "absent") in ("copied", "absent")
              and isinstance(value.get("dump_file"), str) else 1)
sys.exit(1)
EOF
    chmod 755 "${root}/bin/jq-stub"
    cat > "${root}/bin/restic-stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${STUB_LOG}"
daily_backup=0
backup_rc=0
if [[ "${1:-}" == forget || "${1:-}" == prune ]]; then
    printf '%s\n' "forbidden-subcommand" >> "${STUB_LOG}"
    exit 99
fi
if [[ "$*" == *" backup "* && "$*" == *"sjv-daily-prep-"* ]]; then
    daily_backup=1
    backup_rc="${STUB_BACKUP_RC:-0}"
fi
if [[ "$*" == *" snapshots --json "* ]]; then
    if [[ "${STUB_SNAPSHOTS_RC:-0}" -ne 0 ]]; then
        exit "${STUB_SNAPSHOTS_RC}"
    fi
    if [[ -f "${STUB_DAILY_SNAPSHOT}" ]]; then
        if [[ "${STUB_SNAPSHOTS_MULTI:-0}" -eq 1 ]]; then
            printf '%s\n' '[{"id":"fixture-daily-snapshot-id"},{"id":"fixture-duplicate-snapshot-id"}]'
            exit 0
        fi
        printf '%s\n' '[{"id":"fixture-daily-snapshot-id","paths":["/backup/pgbackrest","/backup/preparations/fixture-preparation"]}]'
    else
        printf '%s\n' '[]'
    fi
    exit 0
fi
if [[ "$*" == *" ls --json "* ]]; then
    if [[ "${STUB_LS_RC:-0}" -ne 0 ]]; then
        exit "${STUB_LS_RC}"
    fi
    if [[ "${STUB_LS_MISSING_MANIFEST:-0}" -eq 1 ]]; then
        printf '%s\n' '{"path":"/backup/pgbackrest/backup-manifest.json"}'
    else
        printf '%s\n' '{"path":"/backup/preparations/fixture-preparation/backup-manifest.json"}'
    fi
    [[ "${STUB_LS_MISSING_DUMP:-0}" -eq 1 ]] ||
        printf '%s\n' '{"path":"/backup/preparations/fixture-preparation/dumps/sjv-20261126T120000Z.dump"}'
    [[ "${STUB_LS_MISSING_RUNTIME:-0}" -eq 1 ]] ||
        printf '%s\n' '{"path":"/backup/preparations/fixture-preparation/files/runtime.env"}'
    if [[ -n "${STUB_LS_COPIED_FILES:-}" ]]; then
        [[ "${STUB_LS_MISSING_PATH:-}" == acme ]] ||
            printf '%s\n' '{"path":"/backup/preparations/fixture-preparation/files/acme.json"}'
        [[ "${STUB_LS_MISSING_PATH:-}" == htpasswd ]] ||
            printf '%s\n' '{"path":"/backup/preparations/fixture-preparation/files/dashboard.htpasswd"}'
        [[ "${STUB_LS_MISSING_PATH:-}" == bouncer ]] ||
            printf '%s\n' '{"path":"/backup/preparations/fixture-preparation/files/crowdsec-bouncer-key"}'
        [[ "${STUB_LS_MISSING_PATH:-}" == app-kek ]] ||
            printf '%s\n' '{"path":"/backup/preparations/fixture-preparation/files/app-kek"}'
    fi
    exit 0
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
if [[ "${daily_backup}" -eq 1 && "${backup_rc}" -ne 0 ]]; then
    exit "${backup_rc}"
fi
if [[ "${STUB_EXIT:-0}" -ne 0 ]]; then
    exit "${STUB_EXIT}"
fi
if [[ "${daily_backup}" -eq 1 ]]; then
    : > "${STUB_DAILY_SNAPSHOT}"
fi
exit 0
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

backup_stop_pid() {
    local pid="${1:-}" i=0
    [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || return 0
    kill -TERM "${pid}" 2>/dev/null || true
    while kill -0 "${pid}" 2>/dev/null && [[ "${i}" -lt 40 ]]; do
        sleep 0.05
        i=$(( i + 1 ))
    done
    wait "${pid}" 2>/dev/null || true
}

backup_child_pids() {
    local parent="$1"
    [[ "${parent}" =~ ^[1-9][0-9]*$ ]] || return 0
    ps -o pid= --ppid "${parent}" 2>/dev/null | awk '{print $1}' || true
}

backup_pgid() {
    local pid="$1" pgid=""
    [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || return 0
    pgid="$(ps -o pgid= -p "${pid}" 2>/dev/null | tr -d '[:space:]' || true)"
    printf '%s\n' "${pgid}"
}

backup_comm() {
    local pid="$1" comm=""
    [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || return 0
    comm="$(ps -o comm= -p "${pid}" 2>/dev/null | tr -d '[:space:]' || true)"
    printf '%s\n' "${comm}"
}

backup_pid_seen() {
    local needle="$1" item
    shift
    for item in "$@"; do
        [[ "${item}" == "${needle}" ]] && return 0
    done
    return 1
}

# The heartbeat is the descendant that is a process-group leader and whose
# child is sleep. The first child of the scheduler may be Restic instead.
backup_heartbeat_leader() {
    local root="$1" attempt pid="" child="" pgid="" comm="" sleep_pid="" args=""
    local -a queue=() seen=()
    [[ "${root}" =~ ^[1-9][0-9]*$ ]] || return 1
    for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        queue=("${root}")
        seen=("${root}")
        while [[ "${#queue[@]}" -gt 0 ]]; do
            pid="${queue[0]}"
            if [[ "${#queue[@]}" -le 1 ]]; then
                queue=()
            else
                queue=("${queue[@]:1}")
            fi
            while IFS= read -r child; do
                [[ "${child}" =~ ^[1-9][0-9]*$ ]] || continue
                if backup_pid_seen "${child}" "${seen[@]}"; then
                    continue
                fi
                seen+=("${child}")
                queue+=("${child}")
                pgid="$(backup_pgid "${child}")"
                [[ "${pgid}" == "${child}" ]] || continue
                # Restic is also a process-group leader so its sleep can be
                # signalled with it. The heartbeat is the other group.
                args="$(ps -o args= -p "${child}" 2>/dev/null || true)"
                [[ "${args}" == *restic* ]] && continue
                while IFS= read -r sleep_pid; do
                    comm="$(backup_comm "${sleep_pid}")"
                    if [[ "${comm}" == "sleep" ]]; then
                        printf '%s\n' "${child}"
                        return 0
                    fi
                done < <(backup_child_pids "${child}")
            done < <(backup_child_pids "${pid}")
        done
        sleep 0.05
    done
    return 1
}

backup_wait_epoch() {
    local file="$1" previous="$2" tries="${3:-80}" i=0 current=""
    while [[ "${i}" -lt "${tries}" ]]; do
        if [[ -f "${file}" ]]; then
            current="$(<"${file}")"
            if [[ -n "${current}" && "${current}" != "${previous}" ]]; then
                printf '%s\n' "${current}"
                return 0
            fi
        fi
        sleep 0.1
        i=$(( i + 1 ))
    done
    return 1
}

backup_schedule_delta() {
    local epoch_file="$1" next_file="$2" epoch="" next=""
    [[ -f "${epoch_file}" && -f "${next_file}" ]] || return 1
    epoch="$(<"${epoch_file}")"
    next="$(<"${next_file}")"
    [[ "${epoch}" =~ ^[0-9]+$ && "${next}" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$(( next - epoch ))"
}

backup_wait_delta() {
    local epoch_file="$1" next_file="$2" expected="$3" tries="${4:-40}" i=0 delta=""
    while [[ "${i}" -lt "${tries}" ]]; do
        delta="$(backup_schedule_delta "${epoch_file}" "${next_file}" || true)"
        if [[ "${delta}" == "${expected}" ]]; then
            return 0
        fi
        sleep 0.1
        i=$(( i + 1 ))
    done
    return 1
}

backup_restic_count() {
    local file="$1" count=0
    if [[ -f "${file}" ]]; then
        count="$(grep -c -F ' backup ' "${file}" || true)"
    fi
    printf '%s\n' "${count:-0}"
}

backup_lock_fds_clear() {
    local pid="$1" fd target
    [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ -d "/proc/${pid}/fd" ]] || return 1
    for fd in /proc/"${pid}"/fd/*; do
        [[ -e "${fd}" ]] || continue
        target="$(readlink -- "${fd}" 2>/dev/null || true)"
        case "${target}" in
            */restic-job.lock|*/backup.lock|*/repo.lock) return 1 ;;
        esac
    done
    return 0
}

backup_locks_free() {
    local root="$1"
    flock -n -x "${root}/locks/restic-job.lock" true &&
        flock -n -x "${root}/locks/backup.lock" true &&
        flock -n -x "${root}/locks/repo.lock" true
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
        "SJV_BACKUP_JQ=${root}/bin/jq-stub"
        "SJV_BACKUP_LOCK_WAIT=1"
        "RESTIC_PASSWORD_FILE=${root}/key"
        "RESTIC_REPOSITORY=rest:https://infrastructure-sjv@10.100.101.12:8000/infrastructure-sjv/"
        "RESTIC_REST_PASSWORD=fixture-rest-password-0123"
        "STUB_LOG=${root}/stub.log"
        "STUB_DAILY_SNAPSHOT=${root}/daily-snapshot"
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
    t_check "pgBackRest and preparations are mounted read-only" \
        bash -c 'grep -q "/backup/pgbackrest:ro" "$1" && grep -q "/backup/preparations:ro" "$1" && ! grep -qE "/backup/(dumps|files):ro" "$1"' _ "${compose}"
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
    t_check "wal takes the repository lock without waiting" \
        bash -c 'grep -F -q "flock -s -n 8" "$1" && ! grep -F -q "flock -w" "$1"' _ "${script}"
    t_check "a busy lock retries after 60 seconds by default" \
        grep -F -q 'SJV_BACKUP_WAL_RETRY_SECONDS:-60' "${script}"
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
    local leader="" sleep_pid="" child="" comm=""
    local -a beats=()
    leader="$(backup_heartbeat_leader "${scheduler}" || true)"
    if [[ -n "${leader}" ]]; then
        mapfile -t beats < <(backup_child_pids "${leader}")
        for child in "${beats[@]+"${beats[@]}"}"; do
            comm="$(backup_comm "${child}")"
            if [[ "${comm}" == "sleep" ]]; then
                sleep_pid="${child}"
            fi
        done
    fi
    t_check "the scheduler heartbeat is the sleep process group" \
        bash -c '[[ "$1" =~ ^[1-9][0-9]*$ && "$2" =~ ^[1-9][0-9]*$ ]] && [[ "$(ps -o pgid= -p "$1" | tr -d "[:space:]")" == "$1" ]] && [[ "$(ps -o pgid= -p "$2" | tr -d "[:space:]")" == "$1" ]]' \
        _ "${leader}" "${sleep_pid}"
    sleep 3
    second_epoch="$(<"${root}/state/sjv-backup-wal.epoch")"
    t_check "the next empty WAL check waits for the interval" test "${first_epoch}" != "${second_epoch}"
    kill -TERM "${scheduler}"
    wait "${scheduler}" || true
    sleep 0.2
    t_check "SIGTERM stops the scheduler and its heartbeat" \
        backup_pids_dead "${scheduler}" "${leader}" "${sleep_pid}" "${beats[@]+"${beats[@]}"}"

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
    local leader="" restic_pid="" child="" args=""
    local -a running=() nested=()
    leader="$(backup_heartbeat_leader "${long_job}" || true)"
    mapfile -t running < <(backup_child_pids "${long_job}")
    for child in "${running[@]+"${running[@]}"}"; do
        args="$(ps -o args= -p "${child}" 2>/dev/null || true)"
        if [[ "${args}" == *restic-stub* ]]; then
            restic_pid="${child}"
        fi
        mapfile -t -O "${#nested[@]}" nested < <(backup_child_pids "${child}")
    done
    t_check "the heartbeat group is not the restic process" \
        bash -c '[[ "$1" =~ ^[1-9][0-9]*$ && "$2" =~ ^[1-9][0-9]*$ && "$1" != "$2" ]] && pg1="$(ps -o pgid= -p "$1" | tr -d "[:space:]")" && pg2="$(ps -o pgid= -p "$2" | tr -d "[:space:]")" && [[ "$pg1" == "$1" && "$pg2" == "$2" && "$pg1" != "$pg2" ]]' \
        _ "${leader}" "${restic_pid}"
    wait "${long_job}" || true
    sleep 0.2
    t_check "a finished backup leaves no heartbeat process" \
        backup_pids_dead "${long_job}" "${leader}" "${restic_pid}" "${running[@]+"${running[@]}"}" "${nested[@]+"${nested[@]}"}"
    printf '%s\n' 1 > "${root}/run/heartbeat"
    t_run env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" health
    t_check "a stale heartbeat is unhealthy" test "${T_RC}" -ne 0
}

test_backup_daily_preparation() {
    print_section "Daily preparation integration"
    local root current state first_count second_count
    root="${T_RUN_DIR}/daily-preparation"
    backup_prepare_tree "${root}"
    backup_env "${root}" 0 0
    t_run env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" run daily
    state="${root}/state/sjv-backup-daily.json"
    t_check "a valid current preparation creates one daily snapshot" \
        bash -c '[[ "$1" == 0 ]] && grep -q "\"status\":\"ok\"" "$2" && grep -q "fixture-daily-snapshot-id" "$2"' _ \
            "${T_RC}" "${state}"
    t_check "the daily snapshot carries the preparation tag" \
        grep -q -- "--tag sjv-daily-prep-fixture-preparation" "${root}/stub.log"
    t_check "the verified daily state is the last restorable backup" \
        grep -q '"status":"ok".*"fixture-daily-snapshot-id"' "${root}/state/sjv-backup-last-restorable.json"
    t_check "daily state files are private" \
        bash -c 'for file in "$1"/sjv-backup-daily.json "$1"/sjv-backup-last-attempt.json "$1"/sjv-backup-last-restorable.json "$1"/sjv-backup-daily.failures; do [[ "$(stat -c %a "$file")" == 600 ]] || exit 1; done' _ \
            "${root}/state"
    t_check "daily state has no fixed temporary files" \
        bash -c '! compgen -G "$1/.sjv-backup-*" >/dev/null' _ "${root}/state"
    first_count="$(grep -c -- "backup --exclude .*sjv-daily-prep-fixture-preparation" "${root}/stub.log" || true)"
    t_run env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" run daily
    second_count="$(grep -c -- "backup --exclude .*sjv-daily-prep-fixture-preparation" "${root}/stub.log" || true)"
    t_check "repeating the same preparation does not create a second snapshot" \
        bash -c '[[ "$1" == 0 && "$2" == "$3" && "$2" == 1 ]]' _ "${T_RC}" "${second_count}" "${first_count}"
    cp -- "${root}/state/sjv-backup-daily.json" "${root}/daily-before-wal"
    printf '%s\n' "segment" > "${root}/backup/pgbackrest/archive/000000010000000000000001"
    t_run env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" run wal
    t_check "WAL does not change the daily state" cmp -s \
        "${root}/daily-before-wal" "${root}/state/sjv-backup-daily.json"

    root="${T_RUN_DIR}/daily-invalid"
    backup_prepare_tree "${root}"
    backup_env "${root}" 0 0
    rm -f "${root}/backup/preparations/current"
    t_run env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" run daily
    t_check "missing current skips daily without Restic" \
        bash -c '[[ "$1" -ne 0 ]] && grep -q "skipped-invalid-preparation" "$2" && [[ ! -e "$3" ]]' _ \
            "${T_RC}" "${root}/state/sjv-backup-daily.json" "${root}/stub.log"

    root="${T_RUN_DIR}/daily-symlink"
    backup_prepare_tree "${root}"
    backup_env "${root}" 0 0
    rm -f "${root}/backup/preparations/current"
    ln -s "${root}/backup/preparations/fixture-preparation" "${root}/backup/preparations/current"
    t_run env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" run daily
    t_check "symlink current skips daily" \
        grep -q "skipped-invalid-preparation" "${root}/state/sjv-backup-daily.json"

    root="${T_RUN_DIR}/daily-path"
    backup_prepare_tree "${root}"
    backup_env "${root}" 0 0
    printf '%s\n' "../outside" > "${root}/backup/preparations/current"
    t_run env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" run daily
    t_check "path traversal in current skips daily" \
        grep -q "skipped-invalid-preparation" "${root}/state/sjv-backup-daily.json"

    for invalid_id in "." ".." "a\\b"; do
        root="${T_RUN_DIR}/daily-invalid-${invalid_id//[^A-Za-z0-9]/x}"
        backup_prepare_tree "${root}"
        backup_env "${root}" 0 0
        printf '%s\n' "${invalid_id}" > "${root}/backup/preparations/current"
        t_run env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" run daily
        t_check "preparation ID ${invalid_id} is rejected" \
            grep -q "skipped-invalid-preparation" "${root}/state/sjv-backup-daily.json"
    done

    root="${T_RUN_DIR}/daily-manifest"
    backup_prepare_tree "${root}"
    backup_env "${root}" 0 0
    printf '%s\n' '{"schema":1' > "${root}/backup/preparations/fixture-preparation/backup-manifest.json"
    t_run env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" run daily
    t_check "invalid JSON skips daily" \
        grep -q "skipped-invalid-preparation" "${root}/state/sjv-backup-daily.json"
    printf '%s\n' '{"schema":1,"preparation_id":"other","status":"ready","pgbackrest":"ok","pg_dump":"ok","runtime_config":"ok","wal_archive":"ok","app_kek":"not_required","dump_file":"sjv-20261126T120000Z.dump"}' \
        > "${root}/backup/preparations/fixture-preparation/backup-manifest.json"
    t_run env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" run daily
    t_check "manifest ID mismatch skips daily" \
        grep -q "skipped-invalid-preparation" "${root}/state/sjv-backup-daily.json"
    printf '%s\n' '{"schema":1,"preparation_id":"fixture-preparation","created_at":"2026-11-26T12:00:00Z","status":"incomplete","pgbackrest":"ok","pg_dump":"ok","runtime_config":"ok","wal_archive":"ok","app_kek":"not_required","dump_file":"sjv-20261126T120000Z.dump"}' \
        > "${root}/backup/preparations/fixture-preparation/backup-manifest.json"
    t_run env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" run daily
    t_check "an incomplete manifest skips daily" \
        grep -q "skipped-invalid-preparation" "${root}/state/sjv-backup-daily.json"
    printf '%s\n' '{"schema":1,"preparation_id":"fixture-preparation","created_at":"2026-11-26T12:00:00Z","status":"failed","pgbackrest":"ok","pg_dump":"ok","runtime_config":"ok","wal_archive":"ok","app_kek":"not_required","dump_file":"sjv-20261126T120000Z.dump"}' \
        > "${root}/backup/preparations/fixture-preparation/backup-manifest.json"
    t_run env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" run daily
    t_check "a failed manifest skips daily" \
        grep -q "skipped-invalid-preparation" "${root}/state/sjv-backup-daily.json"
    printf '%s\n' '{"schema":1,"preparation_id":"fixture-preparation","created_at":"2026-11-26T12:00:00Z","status":"ready","pgbackrest":"ok","pg_dump":"ok","runtime_config":"ok","wal_archive":"ok","app_kek":"not_required","dump_file":"sjv-20261126T120000Z.dump"}' \
        > "${root}/backup/preparations/fixture-preparation/backup-manifest.json"
    rm -f "${root}/backup/preparations/fixture-preparation/dumps/sjv-20261126T120000Z.dump"
    t_run env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" run daily
    t_check "a missing dump skips daily" \
        grep -q "skipped-invalid-preparation" "${root}/state/sjv-backup-daily.json"
    printf '%s\n' '{"schema":1,"preparation_id":"fixture-preparation","created_at":"2026-11-26T12:00:00Z","status":"ready","pgbackrest":"ok","pg_dump":"ok","runtime_config":"ok","wal_archive":"ok","app_kek":"missing","dump_file":"sjv-20261126T120000Z.dump"}' \
        > "${root}/backup/preparations/fixture-preparation/backup-manifest.json"
    printf '%s\n' "PGDMPfixture-dump" \
        > "${root}/backup/preparations/fixture-preparation/dumps/sjv-20261126T120000Z.dump"
    chmod 600 "${root}/backup/preparations/fixture-preparation/dumps/sjv-20261126T120000Z.dump"
    t_run env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" run daily
    t_check "missing app-kek state is not accepted as complete" \
        grep -q "skipped-invalid-preparation" "${root}/state/sjv-backup-daily.json"
}

test_backup_daily_restic_errors() {
    print_section "Daily Restic error handling"
    local root saved

    root="${T_RUN_DIR}/daily-snapshots-error"
    backup_prepare_tree "${root}"
    backup_env "${root}" 0 0
    t_run env "${BACKUP_ENV[@]}" STUB_SNAPSHOTS_RC=11 \
        bash "${REPO_ROOT}/backup/sjv-backup.sh" run daily
    t_check "snapshots error returns failure without backup" \
        bash -c '[[ "$1" -ne 0 ]] && grep -q "\"status\":\"failed\"" "$2" && ! grep -q " backup " "$3"' _ \
            "${T_RC}" "${root}/state/sjv-backup-daily.json" "${root}/stub.log"

    root="${T_RUN_DIR}/daily-snapshots-multi"
    backup_prepare_tree "${root}"
    backup_env "${root}" 0 0
    : > "${root}/daily-snapshot"
    t_run env "${BACKUP_ENV[@]}" STUB_SNAPSHOTS_MULTI=1 \
        bash "${REPO_ROOT}/backup/sjv-backup.sh" run daily
    t_check "duplicate preparation tags fail closed" \
        bash -c '[[ "$1" -ne 0 ]] && grep -q "\"status\":\"failed\"" "$2" && ! grep -q " backup " "$3"' _ \
            "${T_RC}" "${root}/state/sjv-backup-daily.json" "${root}/stub.log"

    root="${T_RUN_DIR}/daily-backup-error"
    backup_prepare_tree "${root}"
    backup_env "${root}" 0 0
    t_run env "${BACKUP_ENV[@]}" STUB_BACKUP_RC=12 \
        bash "${REPO_ROOT}/backup/sjv-backup.sh" run daily
    t_check "backup error is recorded with its return code" \
        bash -c '[[ "$1" -eq 12 ]] && grep -q "\"status\":\"failed\"" "$2" && grep -q "\"exit_code\":12" "$2"' _ \
            "${T_RC}" "${root}/state/sjv-backup-daily.json"
    t_check "failed backup does not create a snapshot marker" \
        test ! -e "${root}/daily-snapshot"
    rm -f "${root}/daily-snapshot"
    t_run env STUB_LOG="${root}/stub.log" STUB_DAILY_SNAPSHOT="${root}/daily-snapshot" \
        STUB_BACKUP_RC=0 STUB_EXIT=12 \
        "${root}/bin/restic-stub" --cacert "${root}/certs/rest-server.crt" \
        backup --tag daily --tag sjv-daily-prep-fixture-preparation
    t_check "stub exit failure does not create a snapshot marker" \
        bash -c '[[ "$1" -ne 0 ]] && [[ ! -e "$2" ]]' _ \
            "${T_RC}" "${root}/daily-snapshot"

    root="${T_RUN_DIR}/daily-ls-error"
    backup_prepare_tree "${root}"
    backup_env "${root}" 0 0
    : > "${root}/daily-snapshot"
    t_run env "${BACKUP_ENV[@]}" STUB_LS_RC=13 \
        bash "${REPO_ROOT}/backup/sjv-backup.sh" run daily
    t_check "ls error is recorded as failed" \
        bash -c '[[ "$1" -ne 0 ]] && grep -q "\"status\":\"failed\"" "$2"' _ \
            "${T_RC}" "${root}/state/sjv-backup-daily.json"

    root="${T_RUN_DIR}/daily-missing-manifest"
    backup_prepare_tree "${root}"
    backup_env "${root}" 0 0
    : > "${root}/daily-snapshot"
    t_run env "${BACKUP_ENV[@]}" STUB_LS_MISSING_MANIFEST=1 \
        bash "${REPO_ROOT}/backup/sjv-backup.sh" run daily
    t_check "a snapshot without the preparation manifest is rejected" \
        bash -c '[[ "$1" -ne 0 ]] && grep -q "\"status\":\"failed\"" "$2"' _ \
            "${T_RC}" "${root}/state/sjv-backup-daily.json"

    root="${T_RUN_DIR}/daily-missing-runtime"
    backup_prepare_tree "${root}"
    backup_env "${root}" 0 0
    : > "${root}/daily-snapshot"
    t_run env "${BACKUP_ENV[@]}" STUB_LS_MISSING_RUNTIME=1 \
        bash "${REPO_ROOT}/backup/sjv-backup.sh" run daily
    t_check "a snapshot without runtime.env is rejected" \
        bash -c '[[ "$1" -ne 0 ]] && grep -q "\"status\":\"failed\"" "$2"' _ \
            "${T_RC}" "${root}/state/sjv-backup-daily.json"

    root="${T_RUN_DIR}/daily-missing-dump-in-snapshot"
    backup_prepare_tree "${root}"
    backup_env "${root}" 0 0
    : > "${root}/daily-snapshot"
    t_run env "${BACKUP_ENV[@]}" STUB_LS_MISSING_DUMP=1 \
        bash "${REPO_ROOT}/backup/sjv-backup.sh" run daily
    t_check "a snapshot missing the declared dump is rejected" \
        bash -c '[[ "$1" -ne 0 ]] && grep -q "\"status\":\"failed\"" "$2"' _ \
            "${T_RC}" "${root}/state/sjv-backup-daily.json"

    root="${T_RUN_DIR}/daily-copied-recovery-files"
    backup_prepare_tree "${root}"
    printf '%s\n' "PGDMPfixture-dump" \
        > "${root}/backup/preparations/fixture-preparation/dumps/sjv-20261126T120000Z.dump"
    dd if=/dev/zero of="${root}/backup/preparations/fixture-preparation/files/app-kek" \
        bs=32 count=1 status=none
    printf '%s\n' acme > "${root}/backup/preparations/fixture-preparation/files/acme.json"
    printf '%s\n' htpasswd > "${root}/backup/preparations/fixture-preparation/files/dashboard.htpasswd"
    printf '%s\n' bouncer > "${root}/backup/preparations/fixture-preparation/files/crowdsec-bouncer-key"
    chmod 600 \
        "${root}/backup/preparations/fixture-preparation/files/app-kek" \
        "${root}/backup/preparations/fixture-preparation/files/acme.json" \
        "${root}/backup/preparations/fixture-preparation/files/dashboard.htpasswd" \
        "${root}/backup/preparations/fixture-preparation/files/crowdsec-bouncer-key"
    printf '%s\n' '{"schema":1,"preparation_id":"fixture-preparation","status":"ready","pgbackrest":"ok","pg_dump":"ok","runtime_config":"ok","wal_archive":"ok","app_kek":"copied","acme":"copied","dashboard_htpasswd":"copied","crowdsec_bouncer_key":"copied","dump_file":"sjv-20261126T120000Z.dump"}' \
        > "${root}/backup/preparations/fixture-preparation/backup-manifest.json"
    chmod 600 "${root}/backup/preparations/fixture-preparation/backup-manifest.json"
    backup_env "${root}" 0 0
    t_run env "${BACKUP_ENV[@]}" STUB_LS_COPIED_FILES=1 \
        bash "${REPO_ROOT}/backup/sjv-backup.sh" run daily
    t_check "a snapshot with all copied recovery files is verified" \
        bash -c '[[ "$1" -eq 0 ]] && grep -q "\"status\":\"ok\"" "$2" && grep -q "\"status\":\"ok\"" "$3"' _ \
            "${T_RC}" "${root}/state/sjv-backup-daily.json" \
            "${root}/state/sjv-backup-last-restorable.json"
    : > "${root}/daily-snapshot"
    t_run env "${BACKUP_ENV[@]}" STUB_LS_COPIED_FILES=1 STUB_LS_MISSING_PATH=acme \
        bash "${REPO_ROOT}/backup/sjv-backup.sh" run daily
    t_check "a snapshot missing a copied recovery file is rejected" \
        bash -c '[[ "$1" -ne 0 ]] && grep -q "\"status\":\"failed\"" "$2"' _ \
            "${T_RC}" "${root}/state/sjv-backup-daily.json"

    root="${T_RUN_DIR}/daily-last-restorable"
    backup_prepare_tree "${root}"
    backup_env "${root}" 0 0
    t_run env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" run daily
    saved="$(cat "${root}/state/sjv-backup-last-restorable.json")"
    t_run env "${BACKUP_ENV[@]}" STUB_LS_RC=13 \
        bash "${REPO_ROOT}/backup/sjv-backup.sh" run daily
    t_check "failed verification preserves last-restorable" \
        bash -c '[[ "$1" -ne 0 ]] && cmp -s "$2" "$3"' _ \
            "${T_RC}" "${root}/state/sjv-backup-last-restorable.json" <(printf '%s\n' "${saved}")
}

test_backup_state_guards() {
    print_section "Backup state file guards"
    local root target saved count_before count_after

    root="${T_RUN_DIR}/state-json-symlink"
    backup_prepare_tree "${root}"
    printf '%s\n' sentinel > "${root}/state/target"
    ln -s target "${root}/state/sjv-backup-wal.json"
    backup_env "${root}" 0 0
    t_run env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" run wal
    t_check "a symlinked JSON state target is rejected" \
        bash -c '[[ "$1" -ne 0 ]] && [[ -L "$2" ]] && [[ "$(cat "$3")" == sentinel ]]' _ \
            "${T_RC}" "${root}/state/sjv-backup-wal.json" "${root}/state/target"
    t_check "JSON state rejection leaves no temporary file" \
        bash -c '! compgen -G "$1/.sjv-backup-wal.json.*" >/dev/null' _ "${root}/state"

    root="${T_RUN_DIR}/state-failures-symlink"
    backup_prepare_tree "${root}"
    rm -f "${root}/backup/preparations/current"
    printf '%s\n' sentinel > "${root}/state/target"
    ln -s target "${root}/state/sjv-backup-daily.failures"
    backup_env "${root}" 0 0
    t_run env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" run daily
    t_check "a symlinked daily failure counter is rejected" \
        bash -c '[[ "$1" -ne 0 ]] && [[ -L "$2" ]] && [[ "$(cat "$3")" == sentinel ]]' _ \
            "${T_RC}" "${root}/state/sjv-backup-daily.failures" "${root}/state/target"

    root="${T_RUN_DIR}/state-directory-symlink"
    backup_prepare_tree "${root}"
    target="${root}/outside-state"
    mkdir -m 700 "${target}"
    rmdir "${root}/state"
    ln -s "${target}" "${root}/state"
    backup_env "${root}" 0 0
    t_run env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" run wal
    t_check "a symlinked state directory is rejected" \
        bash -c '[[ "$1" -ne 0 ]] && [[ -L "$2" ]] && [[ -z "$(find "$3" -mindepth 1 -print -quit)" ]]' _ \
            "${T_RC}" "${root}/state" "${target}"

    root="${T_RUN_DIR}/state-directory-mode"
    backup_prepare_tree "${root}"
    chmod 755 "${root}/state"
    backup_env "${root}" 0 0
    t_run env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" run wal
    t_check "a state directory with unsafe mode is rejected" \
        bash -c '[[ "$1" -ne 0 ]] && [[ "$(stat -c %a "$2")" == 755 ]]' _ \
            "${T_RC}" "${root}/state"

    root="${T_RUN_DIR}/state-directory-owner"
    backup_prepare_tree "${root}"
    if chown 65534:65534 "${root}/state" 2>/dev/null; then
        backup_env "${root}" 0 0
        t_run env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" run wal
        t_check "a state directory with unsafe owner is rejected" \
            test "${T_RC}" -ne 0
    else
        t_skip "state directory owner guard needs chown permission"
    fi

    root="${T_RUN_DIR}/last-restorable-write"
    backup_prepare_tree "${root}"
    backup_env "${root}" 0 0
    t_run env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" run daily
    saved="$(cat "${root}/state/sjv-backup-last-restorable.json")"
    count_before="$(grep -c -- " backup --exclude .*sjv-daily-prep-fixture-preparation" "${root}/stub.log" || true)"
    printf '%s\n' "${saved}" > "${root}/state/last-restorable-target"
    rm -f "${root}/state/sjv-backup-last-restorable.json"
    ln -s last-restorable-target "${root}/state/sjv-backup-last-restorable.json"
    t_run env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" run daily
    count_after="$(grep -c -- " backup --exclude .*sjv-daily-prep-fixture-preparation" "${root}/stub.log" || true)"
    t_check "last-restorable write failure is not reported as daily success" \
        bash -c '[[ "$1" -ne 0 ]] && grep -q "\"status\":\"failed-evidence\"" "$2"' _ \
            "${T_RC}" "${root}/state/sjv-backup-daily.json"
    t_check "last-restorable remains unchanged after write failure" \
        bash -c '[[ -L "$1" ]] && cmp -s "$2" "$3"' _ \
            "${root}/state/sjv-backup-last-restorable.json" \
            "${root}/state/last-restorable-target" <(printf '%s\n' "${saved}")
    t_check "evidence failure does not create another snapshot" \
        test "${count_after}" = "${count_before}"
    t_check "last-restorable failure leaves no temporary file" \
        bash -c '! compgen -G "$1/.sjv-backup-last-restorable.json.*" >/dev/null' _ "${root}/state"
}

test_backup_daily_lock_skips() {
    print_section "Daily lock skip evidence"
    local lock_name lock_path expected root holder saved count_before count_after
    for lock_name in restic-job backup repo; do
        root="${T_RUN_DIR}/daily-lock-${lock_name}"
        backup_prepare_tree "${root}"
        backup_env "${root}" 0 0
        t_run env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" run daily
        saved="$(cat "${root}/state/sjv-backup-last-restorable.json")"
        count_before="$(grep -c -- " backup --exclude .*sjv-daily-prep-fixture-preparation" "${root}/stub.log" || true)"
        case "${lock_name}" in
            restic-job)
                lock_path="${root}/locks/restic-job.lock"
                expected="skipped-locked"
                ;;
            backup)
                lock_path="${root}/locks/backup.lock"
                expected="skipped-backup-lock"
                ;;
            repo)
                lock_path="${root}/locks/repo.lock"
                expected="skipped-repo-lock"
                ;;
        esac
        backup_hold_exclusive "${lock_path}"
        holder="${BACKUP_HOLDER}"
        backup_env "${root}" 0 0
        t_run env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" run daily
        count_after="$(grep -c -- " backup --exclude .*sjv-daily-prep-fixture-preparation" "${root}/stub.log" || true)"
        t_check "${lock_name} skip returns 75" test "${T_RC}" -eq 75
        t_check "${lock_name} skip records the lock-specific state and times" \
            bash -c 'grep -q "\"status\":\"$1\"" "$2" && grep -Eq "\"started_at\":\"[^\"]+\".*\"finished_at\":\"[^\"]+\"" "$2"' _ \
                "${expected}" "${root}/state/sjv-backup-daily.json"
        t_check "${lock_name} skip is recorded as the last attempt" \
            grep -q "\"status\":\"${expected}\"" "${root}/state/sjv-backup-last-attempt.json"
        t_check "${lock_name} skip starts no new Restic backup" \
            test "${count_after}" = "${count_before}"
        t_check "${lock_name} skip preserves last-restorable" \
            bash -c 'cmp -s "$1" "$2"' _ \
                "${root}/state/sjv-backup-last-restorable.json" \
                <(printf '%s\n' "${saved}")
        backup_stop_group "${holder}"
    done
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
        "SJV_BACKUP_LOCK_WAIT=600"
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
    t_run env "${BACKUP_ENV[@]}" SJV_BACKUP_LOCK_WAIT=600 bash "${REPO_ROOT}/backup/sjv-backup.sh" run daily
    elapsed="$(( $(date +%s) - started ))"
    t_check "a busy repo.lock skips daily without waiting" \
        bash -c '(( $1 == 75 )) && grep -F -q "\"status\":\"skipped-repo-lock\"" "$2" && (( $3 < 8 ))' \
        _ "${T_RC}" "${root}/state/sjv-backup-daily.json" "${elapsed}"
    backup_env "${root}" 0 0
    BACKUP_ENV+=(
        "SJV_BACKUP_TICK_SECONDS=1"
        "SJV_BACKUP_WAL_SECONDS=60"
        "SJV_BACKUP_DAILY_AT=00:00"
        "SJV_BACKUP_LOCK_WAIT=600"
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
    rm -f "${root}/state/sjv-backup-wal.next"
    printf '%s\n' 0 > "${root}/state/sjv-backup-wal.epoch"
    backup_wait_grep '"status":"skipped-repo-lock"' "${root}/state/sjv-backup-wal.json" 80 || true
    t_check "the scheduler continues and WAL skips a busy repository lock" \
        bash -c 'kill -0 "$1" && [[ -f "$2" ]] && grep -F -q "\"status\":\"skipped-repo-lock\"" "$2" && [[ ! -e "$3" ]]' \
        _ "${scheduler}" "${root}/state/sjv-backup-wal.json" "${root}/stub.log"
    backup_stop_group "${scheduler}"
    backup_stop_group "${holder}"
}

test_backup_wal_schedule() {
    print_section "WAL scheduler retry"
    local root holder="" scheduler=0 long_job=0 started=0 elapsed=0
    local first="" second="" later="" count="" count_after="" leader="" sleep_pid="" now="" child=""
    local stale="" upcoming=""
    root="${T_RUN_DIR}/wal-schedule"
    backup_prepare_tree "${root}"
    mkdir -p "${root}/backup/pgbackrest/archive/sjv/18-1"
    printf 'segment\n' > "${root}/backup/pgbackrest/archive/sjv/18-1/000000010000000000000001"
    printf '%s\n' "$(date +%F)" > "${root}/state/sjv-backup-daily.date"
    if ! backup_hold_exclusive "${root}/locks/repo.lock"; then
        t_fail "the test could not hold repo.lock"
        return 0
    fi
    holder="${BACKUP_HOLDER}"
    backup_env "${root}" 0 0
    BACKUP_ENV+=(
        "SJV_BACKUP_TICK_SECONDS=1"
        "SJV_BACKUP_WAL_SECONDS=300"
        "SJV_BACKUP_WAL_RETRY_SECONDS=5"
        "SJV_BACKUP_DAILY_AT=00:00"
        "SJV_BACKUP_LOCK_WAIT=600"
        "SJV_BACKUP_HEARTBEAT_SECONDS=30"
    )
    rm -f "${root}/stub.log" "${root}/state/sjv-backup-wal.json" \
        "${root}/state/sjv-backup-wal.epoch" "${root}/state/sjv-backup-wal.next"
    started="$(date +%s)"
    env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" supervise >/dev/null 2>&1 &
    scheduler=$!
    first="$(backup_wait_epoch "${root}/state/sjv-backup-wal.epoch" "" 80 || true)"
    elapsed="$(( $(date +%s) - started ))"
    t_check "LOCK_WAIT=600 does not block a WAL skip on a busy repo.lock" \
        bash -c '[[ -n "$1" && "$2" -lt 12 ]] && grep -F -q "\"status\":\"skipped-repo-lock\"" "$3" && [[ ! -e "$4" ]]' \
        _ "${first}" "${elapsed}" "${root}/state/sjv-backup-wal.json" "${root}/stub.log"
    t_check "the scheduler stays alive after the skipped WAL" kill -0 "${scheduler}"
    t_check "a skipped WAL releases the restic job lock" \
        flock -n -x "${root}/locks/restic-job.lock" true
    t_check "a skipped WAL keeps no lock descriptor open" \
        backup_lock_fds_clear "${scheduler}"
    t_check "a busy repo.lock schedules the short retry" \
        backup_wait_delta "${root}/state/sjv-backup-wal.epoch" "${root}/state/sjv-backup-wal.next" 5 20
    sleep 1.5
    second=""
    if [[ -f "${root}/state/sjv-backup-wal.epoch" ]]; then
        second="$(<"${root}/state/sjv-backup-wal.epoch")"
    fi
    t_check "a busy lock does not retry in a tight loop" \
        bash -c '[[ -n "$1" && "$1" == "$2" ]]' _ "${first}" "${second}"
    second="$(backup_wait_epoch "${root}/state/sjv-backup-wal.epoch" "${first}" 120 || true)"
    t_check "the next WAL attempt follows the retry interval" \
        bash -c '[[ -n "$1" && "$1" != "$2" ]] && grep -F -q "\"status\":\"skipped-repo-lock\"" "$3" && [[ ! -e "$4" ]]' \
        _ "${second}" "${first}" "${root}/state/sjv-backup-wal.json" "${root}/stub.log"
    t_check "the retry attempt still schedules the short interval" \
        backup_wait_delta "${root}/state/sjv-backup-wal.epoch" "${root}/state/sjv-backup-wal.next" 5 20
    backup_stop_group "${holder}"
    holder=""
    started="$(date +%s)"
    if flock -n -x "${root}/locks/repo.lock" true; then
        elapsed="$(( $(date +%s) - started ))"
    else
        elapsed=999
    fi
    t_check "a released repo.lock can be taken again without waiting" test "${elapsed}" -lt 3
    later="$(backup_wait_epoch "${root}/state/sjv-backup-wal.epoch" "${second}" 120 || true)"
    count="$(backup_restic_count "${root}/stub.log")"
    t_check "WAL runs after the repository lock is released" \
        bash -c '[[ -n "$1" ]] && grep -F -q "\"status\":\"ok\"" "$2" && grep -F -q -- "--tag wal" "$3"' \
        _ "${later}" "${root}/state/sjv-backup-wal.json" "${root}/stub.log"
    t_check "a successful WAL schedules the normal interval" \
        backup_wait_delta "${root}/state/sjv-backup-wal.epoch" "${root}/state/sjv-backup-wal.next" 300 30
    sleep 6
    second=""
    if [[ -f "${root}/state/sjv-backup-wal.epoch" ]]; then
        second="$(<"${root}/state/sjv-backup-wal.epoch")"
    fi
    count_after="$(backup_restic_count "${root}/stub.log")"
    t_check "a successful WAL is not retried on the short interval" \
        bash -c '[[ -n "$1" && "$1" == "$2" && "$3" == "$4" ]]' \
        _ "${later}" "${second}" "${count}" "${count_after}"
    leader="$(backup_heartbeat_leader "${scheduler}" || true)"
    sleep_pid=""
    if [[ -n "${leader}" ]]; then
        while IFS= read -r child; do
            if [[ "$(backup_comm "${child}")" == "sleep" ]]; then
                sleep_pid="${child}"
            fi
        done < <(backup_child_pids "${leader}")
    fi
    t_check "the scheduler heartbeat is its own process group" \
        bash -c '[[ "$1" =~ ^[1-9][0-9]*$ && "$2" =~ ^[1-9][0-9]*$ ]] && [[ "$(ps -o pgid= -p "$1" | tr -d "[:space:]")" == "$1" ]] && [[ "$(ps -o pgid= -p "$2" | tr -d "[:space:]")" == "$1" ]]' \
        _ "${leader}" "${sleep_pid}"
    backup_stop_pid "${scheduler}"
    scheduler=0
    sleep 0.2
    t_check "the scheduler heartbeat group stops with the scheduler" \
        backup_pids_dead "${leader}" "${sleep_pid}"

    find "${root}/backup/pgbackrest/archive" -mindepth 1 -delete
    rm -f "${root}/stub.log" "${root}/state/sjv-backup-wal.json" \
        "${root}/state/sjv-backup-wal.epoch" "${root}/state/sjv-backup-wal.next"
    backup_env "${root}" 0 0
    BACKUP_ENV+=(
        "SJV_BACKUP_TICK_SECONDS=1"
        "SJV_BACKUP_WAL_SECONDS=300"
        "SJV_BACKUP_WAL_RETRY_SECONDS=3"
        "SJV_BACKUP_LOCK_WAIT=600"
        "SJV_BACKUP_HEARTBEAT_SECONDS=30"
    )
    env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" supervise >/dev/null 2>&1 &
    scheduler=$!
    first="$(backup_wait_epoch "${root}/state/sjv-backup-wal.epoch" "" 80 || true)"
    t_check "an empty archive schedules the normal interval" \
        bash -c '[[ -n "$1" ]] && grep -F -q "\"status\":\"skipped-empty\"" "$2" && [[ ! -e "$3" ]]' \
        _ "${first}" "${root}/state/sjv-backup-wal.json" "${root}/stub.log"
    t_check "an empty archive does not use the short retry" \
        backup_wait_delta "${root}/state/sjv-backup-wal.epoch" "${root}/state/sjv-backup-wal.next" 300 20
    sleep 5
    second=""
    if [[ -f "${root}/state/sjv-backup-wal.epoch" ]]; then
        second="$(<"${root}/state/sjv-backup-wal.epoch")"
    fi
    t_check "an empty archive is not retried every retry interval" \
        bash -c '[[ -n "$1" && "$1" == "$2" ]]' _ "${first}" "${second}"
    backup_stop_pid "${scheduler}"
    scheduler=0

    mkdir -p "${root}/backup/pgbackrest/archive/sjv/18-1"
    printf 'segment\n' > "${root}/backup/pgbackrest/archive/sjv/18-1/000000010000000000000001"
    rm -f "${root}/stub.log" "${root}/state/sjv-backup-wal.json" \
        "${root}/state/sjv-backup-wal.epoch" "${root}/state/sjv-backup-wal.next"
    backup_env "${root}" 1 0
    BACKUP_ENV+=(
        "SJV_BACKUP_TICK_SECONDS=1"
        "SJV_BACKUP_WAL_SECONDS=300"
        "SJV_BACKUP_WAL_RETRY_SECONDS=3"
        "SJV_BACKUP_LOCK_WAIT=600"
        "SJV_BACKUP_HEARTBEAT_SECONDS=30"
    )
    env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" supervise >/dev/null 2>&1 &
    scheduler=$!
    first="$(backup_wait_epoch "${root}/state/sjv-backup-wal.epoch" "" 80 || true)"
    count="$(backup_restic_count "${root}/stub.log")"
    t_check "a Restic error is recorded as failed" \
        bash -c '[[ -n "$1" ]] && grep -F -q "\"status\":\"failed\"" "$2" && ! grep -F -q "skipped-" "$2"' \
        _ "${first}" "${root}/state/sjv-backup-wal.json"
    t_check "a Restic error keeps the normal interval" \
        backup_wait_delta "${root}/state/sjv-backup-wal.epoch" "${root}/state/sjv-backup-wal.next" 300 20
    t_check "the scheduler stays alive after a Restic error" kill -0 "${scheduler}"
    sleep 5
    second=""
    if [[ -f "${root}/state/sjv-backup-wal.epoch" ]]; then
        second="$(<"${root}/state/sjv-backup-wal.epoch")"
    fi
    count_after="$(backup_restic_count "${root}/stub.log")"
    t_check "a Restic error does not retry on the short interval" \
        bash -c '[[ -n "$1" && "$1" == "$2" && "$3" == "$4" ]]' \
        _ "${first}" "${second}" "${count}" "${count_after}"
    backup_stop_pid "${scheduler}"
    scheduler=0

    rm -f "${root}/stub.log" "${root}/state/sjv-backup-wal.json" \
        "${root}/state/sjv-backup-wal.epoch" "${root}/state/sjv-backup-wal.next"
    backup_env "${root}" 0 30
    BACKUP_ENV+=(
        "SJV_BACKUP_TICK_SECONDS=1"
        "SJV_BACKUP_WAL_SECONDS=300"
        "SJV_BACKUP_WAL_RETRY_SECONDS=3"
        "SJV_BACKUP_LOCK_WAIT=600"
        "SJV_BACKUP_HEARTBEAT_SECONDS=30"
        "STUB_OVERLAP_DIR=${root}/stub-overlap"
    )
    env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" run wal >/dev/null 2>&1 &
    long_job=$!
    backup_wait_grep ' backup ' "${root}/stub.log" 80 || true
    started="$(date +%s)"
    env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" supervise >/dev/null 2>&1 &
    scheduler=$!
    backup_wait_grep '"status":"skipped-locked"' "${root}/state/sjv-backup-wal.json" 80 || true
    elapsed="$(( $(date +%s) - started ))"
    count="$(backup_restic_count "${root}/stub.log")"
    t_check "a busy restic job lock skips WAL without a second Restic" \
        bash -c 'kill -0 "$1" && kill -0 "$2" && [[ -f "$3" ]] && grep -F -q "\"status\":\"skipped-locked\"" "$3" && [[ "$4" == 1 ]] && [[ "$5" -lt 12 ]] && ! grep -F -q overlap "$6"' \
        _ "${scheduler}" "${long_job}" "${root}/state/sjv-backup-wal.json" "${count}" "${elapsed}" "${root}/stub.log"
    t_check "the waiting scheduler holds no lock of its own" \
        backup_lock_fds_clear "${scheduler}"
    backup_stop_pid "${scheduler}"
    scheduler=0
    backup_stop_pid "${long_job}"
    long_job=0
    sleep 0.2
    t_check "locks are free after the Restic job exits" backup_locks_free "${root}"

    rm -f "${root}/stub.log" "${root}/state/sjv-backup-daily.json" \
        "${root}/state/sjv-backup-daily.date" "${root}/state/sjv-backup-wal.json" \
        "${root}/state/sjv-backup-wal.epoch"
    now="$(date +%s)"
    printf '%s\n' "${now}" > "${root}/state/sjv-backup-wal.epoch"
    printf '%s\n' "$(( now + 10000 ))" > "${root}/state/sjv-backup-wal.next"
    rmdir "${root}/stub-overlap" 2>/dev/null || true
    backup_env "${root}" 0 0
    BACKUP_ENV+=(
        "SJV_BACKUP_TICK_SECONDS=1"
        "SJV_BACKUP_WAL_SECONDS=300"
        "SJV_BACKUP_WAL_RETRY_SECONDS=3"
        "SJV_BACKUP_DAILY_AT=00:00"
        "SJV_BACKUP_LOCK_WAIT=600"
        "SJV_BACKUP_HEARTBEAT_SECONDS=30"
    )
    env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" supervise >/dev/null 2>&1 &
    scheduler=$!
    backup_wait_grep '"status":"ok"' "${root}/state/sjv-backup-daily.json" 80 || true
    local locks_ready=0 attempt=0
    while [[ "${attempt}" -lt 30 ]]; do
        if backup_locks_free "${root}" && backup_lock_fds_clear "${scheduler}"; then
            locks_ready=1
            break
        fi
        sleep 0.1
        attempt=$(( attempt + 1 ))
    done
    t_check "a finished daily job holds no locks" \
        bash -c '[[ "$1" == 1 && -f "$2" ]] && grep -F -q "\"status\":\"ok\"" "$2"' \
        _ "${locks_ready}" "${root}/state/sjv-backup-daily.json"
    backup_stop_pid "${scheduler}"
    scheduler=0
    t_check "locks stay free after the daily scheduler stops" backup_locks_free "${root}"

    rm -f "${root}/stub.log" "${root}/state/sjv-backup-wal.json" \
        "${root}/state/sjv-backup-daily.json"
    now="$(date +%s)"
    printf '%s\n' "${now}" > "${root}/state/sjv-backup-wal.epoch"
    printf '%s\n' "$(( now + 300 ))" > "${root}/state/sjv-backup-wal.next"
    printf '%s\n' "$(date +%F)" > "${root}/state/sjv-backup-daily.date"
    backup_env "${root}" 0 0
    BACKUP_ENV+=(
        "SJV_BACKUP_TICK_SECONDS=1"
        "SJV_BACKUP_WAL_SECONDS=300"
        "SJV_BACKUP_WAL_RETRY_SECONDS=1"
        "SJV_BACKUP_LOCK_WAIT=600"
        "SJV_BACKUP_HEARTBEAT_SECONDS=30"
    )
    env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" supervise >/dev/null 2>&1 &
    scheduler=$!
    sleep 3
    count="$(backup_restic_count "${root}/stub.log")"
    t_check "a restart waits for the saved next attempt" \
        bash -c 'kill -0 "$1" && [[ "$2" == 0 && "$(<"$3")" == "$4" ]]' \
        _ "${scheduler}" "${count}" "${root}/state/sjv-backup-wal.epoch" "${now}"
    backup_stop_pid "${scheduler}"
    scheduler=0
    rm -f "${root}/state/sjv-backup-wal.next"
    env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" supervise >/dev/null 2>&1 &
    scheduler=$!
    sleep 3
    count="$(backup_restic_count "${root}/stub.log")"
    t_check "a restart with only the last attempt does not run immediately" \
        bash -c '[[ "$1" == 0 && "$(<"$2")" == "$3" ]]' \
        _ "${count}" "${root}/state/sjv-backup-wal.epoch" "${now}"
    backup_stop_pid "${scheduler}"
    scheduler=0
    # next is committed and epoch still has the previous, already overdue attempt.
    now="$(date +%s)"
    stale="$(( now - 10000 ))"
    upcoming="$(( now + 300 ))"
    printf '%s\n' "${stale}" > "${root}/state/sjv-backup-wal.epoch"
    printf '%s\n' "${upcoming}" > "${root}/state/sjv-backup-wal.next"
    rm -f "${root}/stub.log" "${root}/state/sjv-backup-wal.json"
    env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" supervise >/dev/null 2>&1 &
    scheduler=$!
    sleep 3
    count="$(backup_restic_count "${root}/stub.log")"
    first=""
    if [[ -f "${root}/state/sjv-backup-wal.epoch" ]]; then
        first="$(<"${root}/state/sjv-backup-wal.epoch")"
    fi
    second=""
    if [[ -f "${root}/state/sjv-backup-wal.next" ]]; then
        second="$(<"${root}/state/sjv-backup-wal.next")"
    fi
    t_check "a restart honors next when the epoch write did not finish" \
        bash -c 'kill -0 "$1" && [[ "$2" == 0 && "$3" == "$4" && "$5" == "$6" ]]' \
        _ "${scheduler}" "${count}" "${first}" "${stale}" "${second}" "${upcoming}"
    backup_stop_pid "${scheduler}"
    scheduler=0
    printf '%s\n' 1 > "${root}/state/sjv-backup-wal.epoch"
    printf '%s\n' 1 > "${root}/state/sjv-backup-wal.next"
    rm -f "${root}/stub.log" "${root}/state/sjv-backup-wal.json"
    env "${BACKUP_ENV[@]}" bash "${REPO_ROOT}/backup/sjv-backup.sh" supervise >/dev/null 2>&1 &
    scheduler=$!
    first="$(backup_wait_epoch "${root}/state/sjv-backup-wal.epoch" "1" 80 || true)"
    sleep 3
    count="$(backup_restic_count "${root}/stub.log")"
    t_check "a due restart runs once and then waits the normal interval" \
        bash -c '[[ -n "$1" && "$1" != 1 && "$2" == 1 ]] && grep -F -q "\"status\":\"ok\"" "$3"' \
        _ "${first}" "${count}" "${root}/state/sjv-backup-wal.json"
    t_check "the single restart attempt schedules the normal interval" \
        backup_wait_delta "${root}/state/sjv-backup-wal.epoch" "${root}/state/sjv-backup-wal.next" 300 20
    backup_stop_pid "${scheduler}"
    scheduler=0
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

# Replaces the one-exit stub for init-repository. cat config and init are
# different calls. The missing-repository text is supplied by the test.
backup_write_init_stub() {
    local root="$1"
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
joined="$*"
action=""
if [[ "${joined}" == *" cat config" ]]; then
    action=cat
elif [[ "${joined}" == *" init" ]]; then
    action=init
else
    printf '%s\n' "unexpected-command" >> "${STUB_LOG}"
    exit 97
fi
case "${STUB_MODE:-}" in
    exists)
        if [[ "${action}" == init ]]; then
            printf '%s\n' "unexpected-init" >> "${STUB_LOG}"
            exit 99
        fi
        printf '%s\n' '{"id":"fixture-config"}'
        exit 0
        ;;
    absent)
        if [[ "${action}" == init ]]; then
            exit 0
        fi
        count=0
        [[ -f "${STUB_CAT_COUNT}" ]] && count="$(cat "${STUB_CAT_COUNT}")"
        count=$((count + 1))
        printf '%s\n' "${count}" > "${STUB_CAT_COUNT}"
        if [[ "${count}" -eq 1 ]]; then
            [[ -z "${STUB_STDERR:-}" ]] || printf '%s\n' "${STUB_STDERR}" >&2
            exit "${STUB_EXIT:-1}"
        fi
        printf '%s\n' '{"id":"fixture-config"}'
        exit "${STUB_SECOND_EXIT:-0}"
        ;;
    reject)
        if [[ "${action}" == init ]]; then
            printf '%s\n' "unexpected-init" >> "${STUB_LOG}"
            exit 99
        fi
        [[ -z "${STUB_STDERR:-}" ]] || printf '%s\n' "${STUB_STDERR}" >&2
        exit "${STUB_EXIT:-1}"
        ;;
    *)
        printf '%s\n' "unexpected-mode" >> "${STUB_LOG}"
        exit 96
        ;;
esac
EOF
    chmod 755 "${root}/bin/restic-stub"
}

backup_restore_secrets() {
    local root="$1"
    rm -f "${root}/key" "${root}/certs/rest-server.crt"
    printf '%s\n' "fixture-restic-key-not-logged" > "${root}/key"
    chmod 600 "${root}/key"
    printf '%s\n' "fixture-certificate" > "${root}/certs/rest-server.crt"
    chmod 644 "${root}/certs/rest-server.crt"
}

test_backup_init() {
    print_section "Repository initialization"
    local root secret="fixture-rest-password-0123" keytext="fixture-restic-key-not-logged"
    local absent="repository does not exist: unable to open config file: <config/> does not exist"
    local hint="Is there a repository at the following location?"
    local cleaned="rest:https://10.100.101.12:8000/infrastructure-sjv/"
    local script cacert
    probe_lines() {
        local line out=""
        for line in "$@"; do
            out+="${line}"$'\n'
        done
        printf '%s' "${out}"
    }
    root="${T_RUN_DIR}/backup-init"
    script="$(backup_script)"
    if [[ -d "${root}" ]]; then
        find "${root}" -mindepth 1 -delete
    fi
    backup_prepare_tree "${root}"
    backup_write_init_stub "${root}"
    backup_env "${root}" 0 0
    cacert="${root}/certs/rest-server.crt"

    rm -f "${root}/stub.log" "${root}/cat.count"
    t_run env "${BACKUP_ENV[@]}" STUB_MODE=exists bash "${script}" init-repository
    t_check "an existing repository is left in place" \
        bash -c '(( $1 == 0 )) && [[ "$2" == *"repository already exists"* ]] && [[ "$2" != *"scheduler started"* ]] && [[ "$2" != *"fixture-config"* ]] && grep -F -q -- "--cacert $3 cat config" "$4" && ! grep -E -q " init$" "$4" && ! grep -F -q unexpected-init "$4"' \
        _ "${T_RC}" "${T_OUT}" "${cacert}" "${root}/stub.log"
    t_check "the repository URL passed to Restic has no username" \
        bash -c 'grep -F -q "rest-username=infrastructure-sjv" "$1" && ! grep -F -q repository-url-still-has-user "$1"' \
        _ "${root}/stub.log"
    t_check "the rest password and key file stay out of arguments and the log" \
        bash -c '! grep -F -q -e "$2" -e "$3" "$1" && ! printf "%s\n" "$4" | grep -F -q -e "$2" -e "$3"' \
        _ "${root}/stub.log" "${secret}" "${keytext}" "${T_OUT}"

    rm -f "${root}/stub.log" "${root}/cat.count"
    t_run env "${BACKUP_ENV[@]}" STUB_MODE=absent STUB_EXIT=10 \
        STUB_CAT_COUNT="${root}/cat.count" \
        STUB_STDERR="$(probe_lines "${absent}" "${hint}" "${cleaned}")" \
        bash "${script}" init-repository
    t_check "a missing repository is initialized once and read back" \
        bash -c '(( $1 == 0 )) && [[ "$2" == *"repository is ready"* ]] && [[ "$2" != *"scheduler started"* ]] && [[ "$2" != *"fixture-config"* ]] && [[ "$(grep -c -E " cat config$" "$3")" -eq 2 ]] && [[ "$(grep -c -E " init$" "$3")" -eq 1 ]] && grep -F -q -- "--cacert $4 cat config" "$3" && grep -F -q -- "--cacert $4 init" "$3"' \
        _ "${T_RC}" "${T_OUT}" "${root}/stub.log" "${cacert}"

    rm -f "${root}/stub.log" "${root}/cat.count"
    t_run env "${BACKUP_ENV[@]}" STUB_MODE=absent STUB_EXIT=10 \
        STUB_CAT_COUNT="${root}/cat.count" \
        STUB_STDERR="$(probe_lines "Fatal: ${absent}" "${hint}" "${cleaned}")" \
        bash "${script}" init-repository
    t_check "a Fatal prefix on the missing-repository diagnosis still initializes once" \
        bash -c '(( $1 == 0 )) && [[ "$(grep -c -E " init$" "$2")" -eq 1 ]] && [[ "$(grep -c -E " cat config$" "$2")" -eq 2 ]]' \
        _ "${T_RC}" "${root}/stub.log"

    rm -f "${root}/stub.log" "${root}/cat.count"
    t_run env "${BACKUP_ENV[@]}" STUB_MODE=absent STUB_EXIT=10 STUB_SECOND_EXIT=31 \
        STUB_CAT_COUNT="${root}/cat.count" \
        STUB_STDERR="$(probe_lines "${absent}" "${hint}" "${cleaned}")" \
        bash "${script}" init-repository
    t_check "initialization is accepted only when the new configuration can be read" \
        bash -c '(( $1 == 31 )) && [[ "$2" == *"not readable after initialization"* ]] && [[ "$(grep -c -E " init$" "$3")" -eq 1 ]]' \
        _ "${T_RC}" "${T_OUT}" "${root}/stub.log"

    local mode code diagnosis
    while IFS='|' read -r mode code diagnosis <&3; do
        rm -f "${root}/stub.log" "${root}/cat.count"
        t_run env "${BACKUP_ENV[@]}" STUB_MODE=reject STUB_EXIT="${code}" STUB_STDERR="${diagnosis}" \
            bash "${script}" init-repository
        t_check "${mode} does not initialize the repository" \
            bash -c '(( $1 == $2 )) && [[ "$3" == *"repository probe failed"* ]] && [[ "$3" == *"$5"* ]] && [[ ! -e "$4" || "$(grep -c -E " init$" "$4")" -eq 0 ]] && ! grep -F -q unexpected-init "$4"' \
            _ "${T_RC}" "${code}" "${T_OUT}" "${root}/stub.log" "${diagnosis}"
    done 3<<EOF
HTTP 401|21|Fatal: unexpected HTTP response (401): 401 Unauthorized
a certificate error|22|Fatal: tls: failed to verify certificate: x509: certificate signed by unknown authority
a network error|23|Fatal: dial tcp 10.100.101.12:8000: connect: connection refused
a key password error|24|Fatal: wrong password or no key found
another missing-repository diagnosis|25|repository does not exist: config file is missing
EOF

    reject_absent() {
        local name="$1" code="$2"
        shift 2
        rm -f "${root}/stub.log" "${root}/cat.count"
        t_run env "${BACKUP_ENV[@]}" STUB_MODE=reject STUB_EXIT="${code}" \
            STUB_STDERR="$(probe_lines "$@")" \
            bash "${script}" init-repository
        t_check "${name}" \
            bash -c '(( $1 == $2 )) && [[ "$3" == *"repository probe failed"* ]] && [[ "$(grep -c -E " init$" "$4")" -eq 0 ]] && ! grep -F -q unexpected-init "$4"' \
            _ "${T_RC}" "${code}" "${T_OUT}" "${root}/stub.log"
    }
    reject_absent "the standard missing-repository diagnosis with exit 1 does not initialize" \
        1 "${absent}" "${hint}" "${cleaned}"
    reject_absent "a different repository URL does not initialize" \
        10 "${absent}" "${hint}" "rest:https://10.100.101.12:8000/other/"
    reject_absent "a repository URL that still contains the username does not initialize" \
        10 "${absent}" "${hint}" "rest:https://infrastructure-sjv@10.100.101.12:8000/infrastructure-sjv/"
    reject_absent "a missing location question does not initialize" \
        10 "${absent}" "${cleaned}"
    reject_absent "a missing repository URL line does not initialize" \
        10 "${absent}" "${hint}"
    reject_absent "an extra diagnostic line does not initialize" \
        10 "${absent}" "${hint}" "${cleaned}" "unexpected extra line"

    rm -f "${root}/stub.log" "${root}/cat.count"
    t_run env "${BACKUP_ENV[@]}" STUB_MODE=reject STUB_EXIT=26 STUB_STDERR= \
        bash "${script}" init-repository
    t_check "empty probe output does not initialize the repository" \
        bash -c '(( $1 == 26 )) && [[ "$2" == *"repository probe failed"* ]] && [[ "$2" == *"diagnostic was empty"* ]] && [[ "$(grep -c -E " init$" "$3")" -eq 0 ]]' \
        _ "${T_RC}" "${T_OUT}" "${root}/stub.log"

    rm -f "${root}/stub.log" "${root}/cat.count"
    t_run env "${BACKUP_ENV[@]}" STUB_MODE=reject STUB_EXIT=27 \
        STUB_STDERR="probe-marker-visible ${secret} ${keytext} ${root}/key" \
        bash "${script}" init-repository
    t_check "a rejected probe logs its diagnostic without secrets or initialization" \
        bash -c '(( $1 == 27 )) && [[ "$2" == *"repository probe failed"* ]] && [[ "$2" == *"probe-marker-visible"* ]] && [[ "$2" == *"<hidden>"* ]] && [[ "$(grep -c -E " init$" "$3")" -eq 0 ]] && ! grep -F -q unexpected-init "$3" && ! printf "%s\n" "$2" | grep -F -q -e "$4" -e "$5" -e "$6" && ! grep -F -q -e "$4" -e "$5" -e "$6" "$3"' \
        _ "${T_RC}" "${T_OUT}" "${root}/stub.log" "${secret}" "${keytext}" "${root}/key"

    rm -f "${root}/stub.log"
    t_run env "${BACKUP_ENV[@]}" RESTIC_REST_PASSWORD= STUB_MODE=exists bash "${script}" init-repository
    t_check "a missing rest password does not start Restic" \
        bash -c '(( $1 != 0 )) && [[ "$2" == *"configuration is incomplete"* ]] && [[ ! -e "$3" ]]' \
        _ "${T_RC}" "${T_OUT}" "${root}/stub.log"
    rm -f "${root}/key" "${root}/stub.log"
    t_run env "${BACKUP_ENV[@]}" STUB_MODE=exists bash "${script}" init-repository
    t_check "a missing key file does not start Restic" \
        bash -c '(( $1 != 0 )) && [[ ! -e "$2" ]]' _ "${T_RC}" "${root}/stub.log"
    backup_restore_secrets "${root}"
    : > "${root}/key"
    chmod 600 "${root}/key"
    rm -f "${root}/stub.log"
    t_run env "${BACKUP_ENV[@]}" STUB_MODE=exists bash "${script}" init-repository
    t_check "an empty key file does not start Restic" \
        bash -c '(( $1 != 0 )) && [[ ! -e "$2" ]]' _ "${T_RC}" "${root}/stub.log"
    backup_restore_secrets "${root}"
    rm -f "${root}/certs/rest-server.crt" "${root}/stub.log"
    t_run env "${BACKUP_ENV[@]}" STUB_MODE=exists bash "${script}" init-repository
    t_check "a missing certificate does not start Restic" \
        bash -c '(( $1 != 0 )) && [[ ! -e "$2" ]]' _ "${T_RC}" "${root}/stub.log"
    backup_restore_secrets "${root}"
    : > "${root}/certs/rest-server.crt"
    chmod 644 "${root}/certs/rest-server.crt"
    rm -f "${root}/stub.log"
    t_run env "${BACKUP_ENV[@]}" STUB_MODE=exists bash "${script}" init-repository
    t_check "an empty certificate does not start Restic" \
        bash -c '(( $1 != 0 )) && [[ "$2" == *"configuration is incomplete"* ]] && [[ ! -e "$3" ]]' \
        _ "${T_RC}" "${T_OUT}" "${root}/stub.log"
    backup_restore_secrets "${root}"
    rm -f "${root}/key"
    ln -s "${root}/certs/rest-server.crt" "${root}/key"
    rm -f "${root}/stub.log"
    t_run env "${BACKUP_ENV[@]}" STUB_MODE=exists bash "${script}" init-repository
    t_check "a symlinked key file does not start Restic" \
        bash -c '(( $1 != 0 )) && [[ ! -e "$2" ]]' _ "${T_RC}" "${root}/stub.log"
    backup_restore_secrets "${root}"
    rm -f "${root}/certs/rest-server.crt"
    ln -s "${root}/key" "${root}/certs/rest-server.crt"
    rm -f "${root}/stub.log"
    t_run env "${BACKUP_ENV[@]}" STUB_MODE=exists bash "${script}" init-repository
    t_check "a symlinked certificate does not start Restic" \
        bash -c '(( $1 != 0 )) && [[ ! -e "$2" ]]' _ "${T_RC}" "${root}/stub.log"
    backup_restore_secrets "${root}"
    chmod 644 "${root}/key"
    rm -f "${root}/stub.log"
    t_run env "${BACKUP_ENV[@]}" STUB_MODE=exists bash "${script}" init-repository
    t_check "a key file without mode 600 or 400 does not start Restic" \
        bash -c '(( $1 != 0 )) && [[ ! -e "$2" ]]' _ "${T_RC}" "${root}/stub.log"
    backup_restore_secrets "${root}"
    rm -f "${root}/stub.log"
    t_run env "${BACKUP_ENV[@]}" RESTIC_REPOSITORY= STUB_MODE=exists bash "${script}" init-repository
    t_check "an empty repository does not start Restic" \
        bash -c '(( $1 == 0 )) && [[ "$2" == *"remote backup is not configured"* ]] && [[ ! -e "$3" ]]' \
        _ "${T_RC}" "${T_OUT}" "${root}/stub.log"

    backup_restore_secrets "${root}"
    rm -f "${root}/stub.log"
    backup_hold_exclusive "${root}/locks/repo.lock"
    t_run env "${BACKUP_ENV[@]}" STUB_MODE=absent STUB_EXIT=11 \
        STUB_CAT_COUNT="${root}/cat.count" STUB_STDERR="${absent}" \
        bash "${script}" init-repository
    backup_stop_group "${BACKUP_HOLDER}"
    BACKUP_HOLDER=""
    t_check "a second initialization cannot take a busy repository lock" \
        bash -c '(( $1 != 0 )) && [[ "$2" == *"repository lock was not free"* ]] && [[ ! -e "$3" ]]' \
        _ "${T_RC}" "${T_OUT}" "${root}/stub.log"
    t_check "initialization does not forget, prune or disable TLS" \
        bash -c '! grep -E -q "(^|[[:space:]])(forget|prune|--insecure-tls)([[:space:]]|$)" "$1"' _ "${script}"
}

test_prepare_repository_username() {
    print_section "Repository username"
    local root secret="fixture-rest-password-0123" keytext="fixture-restic-key-not-logged"
    local script bare="rest:https://10.100.101.12:8000/infrastructure-sjv/"
    root="${T_RUN_DIR}/backup-username"
    script="$(backup_script)"
    if [[ -d "${root}" ]]; then
        find "${root}" -mindepth 1 -delete
    fi
    backup_prepare_tree "${root}"
    backup_env "${root}" 0 0

    rm -f "${root}/stub.log"
    t_run env -u RESTIC_REST_USERNAME "${BACKUP_ENV[@]}" \
        RESTIC_REPOSITORY="${bare}" RESTIC_REST_USERNAME=infrastructure-sjv \
        bash "${script}" init-repository
    t_check "a URL without a user keeps RESTIC_REST_USERNAME" \
        bash -c '(( $1 == 0 )) && grep -F -q "rest-username=infrastructure-sjv" "$2" && ! grep -F -q repository-url-still-has-user "$2" && grep -F -q rest-password-present "$2" && grep -F -q key-file-present "$2"' \
        _ "${T_RC}" "${root}/stub.log"
    t_check "the preserved username run does not log either password" \
        bash -c '! grep -F -q -e "$2" -e "$3" "$1" && ! printf "%s\n" "$4" | grep -F -q -e "$2" -e "$3"' \
        _ "${root}/stub.log" "${secret}" "${keytext}" "${T_OUT}"

    rm -f "${root}/stub.log"
    t_run env -u RESTIC_REST_USERNAME "${BACKUP_ENV[@]}" bash "${script}" init-repository
    t_check "a username in the URL is extracted and removed" \
        bash -c '(( $1 == 0 )) && grep -F -q "rest-username=infrastructure-sjv" "$2" && ! grep -F -q repository-url-still-has-user "$2"' \
        _ "${T_RC}" "${root}/stub.log"

    rm -f "${root}/stub.log"
    t_run env -u RESTIC_REST_USERNAME "${BACKUP_ENV[@]}" \
        RESTIC_REPOSITORY="${bare}" bash "${script}" init-repository
    t_check "a URL without a user and without a username stays empty" \
        bash -c '(( $1 == 0 )) && ! grep -F -q "rest-username=" "$2" && ! grep -F -q repository-url-still-has-user "$2" && grep -F -q rest-password-present "$2" && grep -F -q key-file-present "$2" && ! grep -F -q -e "$3" -e "$4" "$2"' \
        _ "${T_RC}" "${root}/stub.log" "${secret}" "${keytext}"
}

test_redact_literal() {
    print_section "Probe diagnostic redaction"
    local root script
    root="${T_RUN_DIR}/backup-redact"
    script="$(backup_script)"
    if [[ -d "${root}" ]]; then
        find "${root}" -mindepth 1 -delete
    fi
    backup_prepare_tree "${root}"
    backup_write_init_stub "${root}"
    backup_env "${root}" 0 0

    redact_case() {
        local name="$1" code="$2" secret="$3" diagnosis="$4" expect="$5"
        rm -f "${root}/stub.log"
        t_run timeout 2 env "${BACKUP_ENV[@]}" STUB_MODE=reject STUB_EXIT="${code}" \
            RESTIC_REST_PASSWORD="${secret}" \
            STUB_STDERR="${diagnosis}" \
            bash "${script}" init-repository
        t_check "${name}" \
            bash -c '(( $1 == $2 )) && [[ "$3" == *"$4"* ]] && [[ "$(grep -c -E " init$" "$5")" -eq 0 ]] && ! grep -F -q unexpected-init "$5" && ! printf "%s\n" "$3" | grep -F -q -e "$6" && ! grep -F -q -e "$6" "$5"' \
            _ "${T_RC}" "${code}" "${T_OUT}" "${expect}" "${root}/stub.log" "${secret}"
    }

    redact_case "a normal password is removed from the probe log" \
        41 "secret-value-123" \
        "before secret-value-123 after" \
        "before <hidden> after"
    redact_case "every copy of a password on one line is removed" \
        42 "secret-value-123" \
        "left secret-value-123 mid secret-value-123 right" \
        "left <hidden> mid <hidden> right"
    redact_case "a password containing glob characters is removed literally" \
        43 'a*b?c[d]' \
        'pre a*b?c[d] and a*b?c[d] post' \
        "pre <hidden> and <hidden> post"
    redact_case "text around a redacted password stays in the probe log" \
        44 "secret-value-123" \
        "head secret-value-123 tail" \
        "head <hidden> tail"
    redact_case "an asterisk password cannot loop and stays out of the log" \
        45 '*' \
        'keep * this * text' \
        "keep <hidden> this <hidden> text"
}

run_backup_tests() {
    print_header "Remote backup"
    test_backup_compose
    test_backup_run
    test_backup_daily_preparation
    test_backup_daily_restic_errors
    test_backup_state_guards
    test_backup_daily_lock_skips
    test_backup_locks
    test_backup_wal_schedule
    test_backup_init
    test_redact_literal
    test_prepare_repository_username
    test_backup_image
}
