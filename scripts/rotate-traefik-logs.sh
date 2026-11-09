#!/usr/bin/env bash
# Rotates Traefik's access log in place. Does not call Docker and does not
# rotate traefik.log: Traefik does that itself. Safe to run repeatedly.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/config.sh
source "${SCRIPT_DIR}/config.sh"
# shellcheck source=scripts/lib/logging.sh
source "${SCRIPT_DIR}/lib/logging.sh"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/deploy/logs.sh
source "${SCRIPT_DIR}/lib/deploy/logs.sh"
log_install_err_trap

FORCE=0
case "${1:-}" in
    "") ;;
    --force) FORCE=1 ;;
    --help)
        printf '%s\n' "Usage: ./scripts/rotate-traefik-logs.sh [--force]" \
            "copytruncate of access.log when it reaches 20 MiB or is older than a day." \
            "--force rotates a non-empty file without waiting for that threshold." \
            "traefik.log is left to Traefik. Docker is not called."
        exit 0
        ;;
    *) fail "Unknown option: $1" ;;
esac

print_header "Rotate Traefik access log"
[[ "${SJV_TEST_MODE}" -eq 0 ]] || warn "Test mode: using ${BASE_DIR} instead of ${PRODUCTION_BASE_DIR}."
require_root
require_mountpoint "${BASE_DIR}"
require_command gzip
require_command truncate
require_command sync
require_command date
require_command find
require_command cp
require_command mktemp
require_command stat
require_command readlink
trap log_rotate_cleanup EXIT
log_rotate_access "${FORCE}"
print_footer "Access log rotation finished. traefik.log was not touched."
