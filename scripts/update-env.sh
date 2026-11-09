#!/usr/bin/env bash
# Creates or updates the runtime .env from the stack copy of .env.example.
# Existing user values and secrets are kept; a changed file is backed up first.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/config.sh
source "${SCRIPT_DIR}/config.sh"
# shellcheck source=scripts/lib/logging.sh
source "${SCRIPT_DIR}/lib/logging.sh"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/env/env.sh
source "${SCRIPT_DIR}/lib/env/env.sh"
log_install_err_trap

case "${1:-}" in
    "") ;;
    --help)
        printf '%s\n' "Usage: ./scripts/update-env.sh" "Synchronizes ${ENV_FILE} with .env.example. Secret values are never printed."
        exit 0
        ;;
    *) fail "Unknown option: $1" ;;
esac

print_header "Update runtime environment"
[[ "${SJV_TEST_MODE}" -eq 0 ]] || warn "Test mode: using ${BASE_DIR} instead of ${PRODUCTION_BASE_DIR}."
check_environment
require_mountpoint "${BASE_DIR}"
[[ -d "${STACK_DIR}" ]] || fail "Stack directory is missing. Run ./scripts/init.sh first."
[[ -f "${STACK_DIR}/.env.example" ]] || fail "Stack is missing .env.example. Run ./scripts/init.sh."
if ! cmp -s "${ENV_EXAMPLE_FILE}" "${STACK_DIR}/.env.example"; then
    fail "The stack copy of .env.example differs from Git. Run ./scripts/init.sh first."
fi

umask 077
acquire_lock "${ENV_LOCK_FILE}" "${LOCK_WAIT_SECONDS}"
env_sync_file "${STACK_DIR}/.env.example" "${ENV_FILE}"

mapfile -t pending < <(env_list_placeholders "${ENV_FILE}")
if (( ${#pending[@]} > 0 )); then
    warn "Still placeholders (edit ${ENV_FILE}): ${pending[*]}"
fi
print_footer "Next: replace the remaining set_ values, then run ./scripts/check-env.sh"
