#!/usr/bin/env bash
# Registers the CrowdSec bouncer after the container is running.
# The API key is written to the key file and is never printed.
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
# shellcheck source=scripts/lib/deploy/layout.sh
source "${SCRIPT_DIR}/lib/deploy/layout.sh"
# shellcheck source=scripts/lib/deploy/docker.sh
source "${SCRIPT_DIR}/lib/deploy/docker.sh"
# shellcheck source=scripts/lib/deploy/networks.sh
source "${SCRIPT_DIR}/lib/deploy/networks.sh"
# shellcheck source=scripts/lib/deploy/crowdsec.sh
source "${SCRIPT_DIR}/lib/deploy/crowdsec.sh"
# shellcheck source=scripts/lib/deploy/render.sh
source "${SCRIPT_DIR}/lib/deploy/render.sh"
log_install_err_trap

case "${1:-}" in
    "") ;;
    --help)
        printf '%s\n' "Usage: ./scripts/post-deploy.sh" \
            "Registers the Traefik bouncer with CrowdSec and restarts Traefik when the key changed."
        exit 0
        ;;
    *) fail "Unknown option: $1" ;;
esac

print_header "${PROJECT_NAME} post-deploy"
[[ "${SJV_TEST_MODE}" -eq 0 ]] || warn "Test mode: using ${BASE_DIR} instead of ${PRODUCTION_BASE_DIR}."
check_environment
require_mountpoint "${BASE_DIR}"
if [[ "${SJV_TEST_MODE}" -eq 1 ]]; then
    fail "Test mode cannot register a CrowdSec bouncer."
fi
require_command docker
env_load_runtime
post_deploy_crowdsec
print_footer "Post-deploy completed. The bouncer key was not printed."
