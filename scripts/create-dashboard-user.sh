#!/usr/bin/env bash
# Stores a bcrypt dashboard password outside Git. The password is typed into
# htpasswd and is not read or printed by this script.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/config.sh
source "${SCRIPT_DIR}/config.sh"
# shellcheck source=scripts/lib/logging.sh
source "${SCRIPT_DIR}/lib/logging.sh"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
log_install_err_trap

case "${1:-}" in
    "") ;;
    --help)
        printf '%s\n' "Usage: ./scripts/create-dashboard-user.sh" \
            "Writes ${HTPASSWD_FILE} (mode 600). The password is not logged."
        exit 0
        ;;
    *) fail "Unknown option: $1" ;;
esac

print_header "Dashboard BasicAuth"
check_environment
require_mountpoint "${BASE_DIR}"
require_command htpasswd
[[ -d "${TRAEFIK_DIR}/users" && ! -L "${TRAEFIK_DIR}/users" ]] \
    || fail "Dashboard user directory is missing. Run ./scripts/init.sh."
read -rp "Username [admin]: " username
username="${username:-admin}"
[[ "${username}" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || fail "Unsupported username."
if [[ -L "${HTPASSWD_FILE}" ]]; then
    fail "${HTPASSWD_FILE} is a symlink. Refusing to replace it."
fi
if [[ -f "${HTPASSWD_FILE}" ]]; then
    htpasswd -B "${HTPASSWD_FILE}" "${username}"
    ok "Updated ${username} in the dashboard password file. Other accounts were kept."
else
    htpasswd -cB "${HTPASSWD_FILE}" "${username}"
    ok "Dashboard credentials stored. The password was not logged."
fi
chmod 600 "${HTPASSWD_FILE}"
