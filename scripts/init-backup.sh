#!/usr/bin/env bash
# Initializes the configured remote Restic repository once.
# Does not start the backup scheduler. An empty repository is left untouched.
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
# shellcheck source=scripts/lib/deploy/docker.sh
source "${SCRIPT_DIR}/lib/deploy/docker.sh"
log_install_err_trap

case "${1:-}" in
    "") ;;
    --help)
        printf '%s\n' "Usage: ./scripts/init-backup.sh" \
            "Initializes the remote Restic repository when RESTIC_REPOSITORY is set." \
            "An empty RESTIC_REPOSITORY does not start Restic or Docker." \
            "The backup scheduler is not started."
        exit 0
        ;;
    *) fail "Unknown option: $1" ;;
esac

# The key file and certificate stay files. Their contents are not read here.
init_backup_ready() {
    local key="${SECRETS_DIR}/restic-key-password"
    local cert="${SECRETS_DIR}/restic-rest-server.crt"
    local mode_bits
    [[ -n "${RUNTIME_ENV[RESTIC_REST_PASSWORD]:-}" ]] || return 1
    [[ -f "${key}" && ! -L "${key}" && -s "${key}" ]] || return 1
    mode_bits="$(stat -c '%a' "${key}")"
    [[ "${mode_bits}" == 600 || "${mode_bits}" == 400 ]] || return 1
    [[ -f "${cert}" && ! -L "${cert}" && -s "${cert}" ]]
}

print_header "${PROJECT_NAME} backup repository"
[[ "${SJV_TEST_MODE}" -eq 0 ]] || warn "Test mode: using ${BASE_DIR} instead of ${PRODUCTION_BASE_DIR}."
check_environment
require_mountpoint "${BASE_DIR}"
env_load_runtime
if [[ -z "${RUNTIME_ENV[RESTIC_REPOSITORY]:-}" ]]; then
    info "Remote backup is not configured. The repository was not initialized."
    print_footer "Remote backup initialization skipped. Next: ./scripts/post-deploy.sh"
    exit 0
fi
if ! init_backup_ready; then
    fail "Remote backup configuration is incomplete. The repository was not initialized."
fi
if [[ "${SJV_TEST_MODE}" -eq 1 ]]; then
    fail "Test mode cannot initialize the remote backup repository."
fi
require_command docker
docker_compose_init_backup
print_footer "Remote backup repository is ready. Next: ./scripts/post-deploy.sh"
