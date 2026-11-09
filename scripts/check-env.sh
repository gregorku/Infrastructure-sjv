#!/usr/bin/env bash
# Read-only check of the runtime .env and the protection of files that hold
# secrets. Exits non-zero on any problem. Changes nothing.
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
        printf '%s\n' "Usage: ./scripts/check-env.sh" "Validates ${ENV_FILE} without changing anything."
        exit 0
        ;;
    *) fail "Unknown option: $1" ;;
esac

check_private_dir() {
    local path="$1" mode
    [[ -e "${path}" ]] || { warn "${path} does not exist yet. Run ./scripts/init.sh."; return 0; }
    [[ -d "${path}" && ! -L "${path}" ]] || fail "${path} is not a directory."
    [[ "$(file_owner "${path}")" == "${EUID}" ]] || fail "${path} is not owned by uid ${EUID}."
    mode="$(file_mode "${path}")"
    [[ "${mode}" == 700 ]] || fail "${path} has mode ${mode}. It must be 700."
}

check_env_backups() {
    local file count=0
    while IFS= read -r -d '' file; do
        count=$((count + 1))
        [[ ! -L "${file}" ]] || fail "Backup ${file##*/} is a symlink."
        assert_private_file "${file}"
    done < <(find "${STACK_DIR}" -maxdepth 1 -name '.env.bak-*' -print0)
    if (( count > 0 )); then
        ok "${count} .env backup(s) are private (mode 600)."
    fi
    if [[ -n "$(find "${STACK_DIR}" -maxdepth 1 -name '.env.tmp.*' -print -quit)" ]]; then
        fail "A temporary .env file from an interrupted update exists in ${STACK_DIR}. Inspect and remove it."
    fi
}

print_header "Check environment"
[[ "${SJV_TEST_MODE}" -eq 0 ]] || warn "Test mode: using ${BASE_DIR} instead of ${PRODUCTION_BASE_DIR}."
check_environment
require_mountpoint "${BASE_DIR}"

print_section "Files"
if path_present "${GIT_DIR}/.env"; then
    fail "A runtime .env exists inside the Git checkout (${GIT_DIR}/.env), or that path is a symlink. Move it out."
fi
if [[ -f "${STACK_DIR}/.env.example" ]] && ! cmp -s "${ENV_EXAMPLE_FILE}" "${STACK_DIR}/.env.example"; then
    warn "The stack copy of .env.example differs from Git. Run ./scripts/init.sh and ./scripts/update-env.sh."
fi
check_private_dir "${STATE_DIR}"
check_private_dir "${SECRETS_DIR}"
check_private_dir "${BACKUP_LOCAL_DIR}"

print_section "Runtime .env"
env_load_runtime
ok "${ENV_FILE} is owned by uid ${EUID} and has mode 600."
check_env_backups

print_footer "Environment checks passed."
