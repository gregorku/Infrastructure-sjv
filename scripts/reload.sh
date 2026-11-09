#!/usr/bin/env bash
# Renders the runtime again and reconciles Traefik and CrowdSec.
# This is the same idempotent path as deploy.sh. Networks are not removed.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/logging.sh
source "${SCRIPT_DIR}/lib/logging.sh"
log_install_err_trap

case "${1:-}" in
    ""|--render-only|--help) ;;
    *) fail "Unknown option: $1" ;;
esac

exec "${SCRIPT_DIR}/deploy.sh" "$@"
