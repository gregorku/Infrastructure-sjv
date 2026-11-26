#!/usr/bin/env bash
# Creates one set of PostgreSQL backup materials and one Restic daily snapshot.
# Does not create app-kek, does not expire WAL, and does not start the scheduler.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/config.sh
source "${SCRIPT_DIR}/config.sh"
# shellcheck source=scripts/lib/logging.sh
source "${SCRIPT_DIR}/lib/logging.sh"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/deploy/docker.sh
source "${SCRIPT_DIR}/lib/deploy/docker.sh"
# shellcheck source=scripts/lib/backup/local.sh
source "${SCRIPT_DIR}/lib/backup/local.sh"
log_install_err_trap

backup_usage() {
    printf '%s\n' \
        "Usage: ./scripts/backup.sh [run|status]" \
        "run creates and publishes one local preparation for the sjv-backup scheduler." \
        "The scheduler is the only owner of daily Restic snapshots. status prints the last result." \
        "app-kek is copied only when it already exists. restic-key-password is never copied." \
        "pgbackrest expire, restic forget and restic prune are not called."
}

action="${1:-run}"
[[ $# -le 1 ]] || fail "Unknown option: $2"
case "${action}" in
    --help)
        backup_usage
        exit 0
        ;;
    run|status) ;;
    *) fail "Unknown option: ${action}" ;;
esac

require_root
require_mountpoint "${BASE_DIR}"

case "${action}" in
    status) backup_show_status ;;
    run)
        if [[ "${SJV_TEST_MODE}" -eq 0 ]]; then
            require_command docker
        fi
        backup_run_main
        ;;
esac
