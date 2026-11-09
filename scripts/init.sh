#!/usr/bin/env bash
# Prepares the host layout and copies secret-free stack files.
# Safe to run repeatedly. Does not touch .env, containers or data.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/config.sh
source "${SCRIPT_DIR}/config.sh"
# shellcheck source=scripts/lib/logging.sh
source "${SCRIPT_DIR}/lib/logging.sh"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/deploy/layout.sh
source "${SCRIPT_DIR}/lib/deploy/layout.sh"
log_install_err_trap

case "${1:-}" in
    "") ;;
    --help)
        printf '%s\n' "Usage: ./scripts/init.sh" "Creates the directory layout under ${BASE_DIR} and copies .env.example into the stack."
        exit 0
        ;;
    *) fail "Unknown option: $1" ;;
esac

print_header "${PROJECT_NAME} initialization"
[[ "${SJV_TEST_MODE}" -eq 0 ]] || warn "Test mode: using ${BASE_DIR} instead of ${PRODUCTION_BASE_DIR}."
check_environment
require_mountpoint "${BASE_DIR}"
layout_prepare
layout_sync_stack
if [[ -f "${ENV_FILE}" ]]; then
    info "Runtime .env exists and was not changed."
fi
print_footer "Initialization completed. Next: ./scripts/update-env.sh"
