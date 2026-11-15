#!/usr/bin/env bash
# Renders the Traefik runtime and, outside test mode, starts Traefik and CrowdSec.
# Safe to run repeatedly. Does not remove networks, volumes or foreign containers.
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

RENDER_ONLY=0
case "${1:-}" in
    "") ;;
    --render-only) RENDER_ONLY=1 ;;
    --help)
        printf '%s\n' "Usage: ./scripts/deploy.sh [--render-only]" \
            "Validates .env, renders Traefik and starts sjv-traefik and sjv-crowdsec." \
            "--render-only writes the runtime files and does not call Docker."
        exit 0
        ;;
    *) fail "Unknown option: $1" ;;
esac

print_header "${PROJECT_NAME} deploy"
[[ "${SJV_TEST_MODE}" -eq 0 ]] || warn "Test mode: using ${BASE_DIR} instead of ${PRODUCTION_BASE_DIR}."
check_environment
require_mountpoint "${BASE_DIR}"
if [[ "${SJV_TEST_MODE}" -eq 1 && "${RENDER_ONLY}" -eq 0 ]]; then
    fail "Test mode cannot create Docker networks or start containers. Use --render-only."
fi
env_load_runtime
if [[ "${RENDER_ONLY}" -eq 0 ]]; then
    require_command docker
fi
layout_prepare
layout_sync_stack
deploy_render_runtime
if [[ "${RENDER_ONLY}" -eq 1 ]]; then
    print_footer "Runtime configuration rendered. Docker was not called."
    exit 0
fi
deploy_ensure_networks
deploy_assert_own_containers
print_section "Compose"
if [[ "${RUNTIME_ENV[PROXY_PROTOCOL_MODE]}" == haproxy ]]; then
    info "Entrypoints web and websecure trust PROXY protocol only from ${RUNTIME_ENV[PROXY_PROTOCOL_TRUSTED_IPS]}. Confirm that address is the live HAProxy source during the operational test."
fi
if [[ "${RUNTIME_ENV[TRAEFIK_TLS_MODE]}" == letsencrypt ]]; then
    info "Let's Encrypt will request a certificate for ${RUNTIME_ENV[SJV_DOMAIN]}."
    if [[ "${RUNTIME_ENV[MQTT_HOSTNAME],,}" != "${RUNTIME_ENV[SJV_DOMAIN],,}" ]]; then
        info "Let's Encrypt will request a separate certificate for ${RUNTIME_ENV[MQTT_HOSTNAME]}. It stays in acme.json for a later Mosquitto handoff."
    fi
fi
docker_compose up -d traefik crowdsec
ok "Traefik and CrowdSec were reconciled. Other projects were not changed."
deploy_crowdsec_install_collections
print_footer "Deploy completed. Next: ./scripts/post-deploy.sh"
