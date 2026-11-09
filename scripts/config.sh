#!/usr/bin/env bash
# Project constants. Sourced by every script; defines no behaviour of its own.
# shellcheck disable=SC2034 # every consumer reads these after sourcing this file

set -Eeuo pipefail

readonly PROJECT_NAME="Infrastructure-sjv"
readonly STACK_NAME="infrastructure-sjv"

SCRIPT_DIR_RESOLVED="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR_RESOLVED}/.." && pwd)"
readonly SCRIPT_DIR_RESOLVED REPO_ROOT
readonly GIT_DIR="${REPO_ROOT}"
readonly TEST_TMP_ROOT="${REPO_ROOT}/.test-tmp"

# Returns 0 when PATH is exactly TEST_ROOT/<one component>/base.
# The checkout path is compared as text, never as a regular expression.
# Every component from / down must be a real directory: a symlink, ".", ".."
# or an extra slash makes the path unusable for test mode.
sjv_test_base_acceptable() {
    local path="$1" test_root="$2" rel cursor rest part physical
    [[ "${path}" == "${test_root}/"* ]] || return 1
    rel="${path#"${test_root}/"}"
    [[ "${rel}" =~ ^[A-Za-z0-9._-]+/base$ ]] || return 1
    cursor=""
    rest="${path#/}"
    while [[ -n "${rest}" ]]; do
        part="${rest%%/*}"
        if [[ "${rest}" == */* ]]; then
            rest="${rest#*/}"
        else
            rest=""
        fi
        [[ -n "${part}" && "${part}" != "." && "${part}" != ".." ]] || return 1
        cursor="${cursor}/${part}"
        [[ -L "${cursor}" ]] && return 1
        [[ -d "${cursor}" ]] || return 1
    done
    physical="$(cd -- "${path}" && pwd -P)" || return 1
    [[ "${physical}" == "${path}" ]]
}

# SJV_TEST_BASE_DIR replaces /docker-data for the automated tests only.
# It must be a directory created by scripts/test.sh inside .test-tmp of this
# checkout, so a stray variable can never redirect a real installation.
if [[ -n "${SJV_TEST_BASE_DIR:-}" ]]; then
    if ! sjv_test_base_acceptable "${SJV_TEST_BASE_DIR}" "${TEST_TMP_ROOT}"; then
        printf '%s\n' "SJV_TEST_BASE_DIR must be an existing test directory under ${TEST_TMP_ROOT}." >&2
        exit 1
    fi
    readonly SJV_TEST_MODE=1
    readonly BASE_DIR="${SJV_TEST_BASE_DIR}"
else
    readonly SJV_TEST_MODE=0
    readonly BASE_DIR="/docker-data"
fi

readonly PRODUCTION_BASE_DIR="/docker-data"
readonly DATA_DIR="${BASE_DIR}/${STACK_NAME}"
readonly STACKS_DIR="${BASE_DIR}/stacks"
readonly STACK_DIR="${STACKS_DIR}/${STACK_NAME}"
readonly BACKUP_LOCAL_DIR="${BASE_DIR}/backups/${STACK_NAME}"
readonly STATE_DIR="${DATA_DIR}/state"
readonly SECRETS_DIR="${DATA_DIR}/secrets"
readonly TRAEFIK_DIR="${DATA_DIR}/traefik"
readonly CROWDSEC_DIR="${DATA_DIR}/crowdsec"
readonly ACME_FILE="${TRAEFIK_DIR}/acme/acme.json"
readonly HTPASSWD_FILE="${TRAEFIK_DIR}/users/dashboard.htpasswd"
readonly RUNTIME_DIR="${STACK_DIR}/runtime"

# Values written into .env must describe the production layout even in tests.
readonly PRODUCTION_DATA_DIR="${PRODUCTION_BASE_DIR}/${STACK_NAME}"
readonly PRODUCTION_BACKUP_LOCAL_DIR="${PRODUCTION_BASE_DIR}/backups/${STACK_NAME}"

readonly ENV_FILE="${STACK_DIR}/.env"
readonly ENV_EXAMPLE_FILE="${GIT_DIR}/.env.example"
readonly ENV_LOCK_FILE="${STACK_DIR}/.env.lock"
readonly ENV_BACKUP_PREFIX="${ENV_FILE}.bak-"
readonly ENV_BACKUP_WARN_COUNT=20
if [[ "${SJV_TEST_MODE}" -eq 1 ]]; then
    readonly LOCK_WAIT_SECONDS=1
else
    readonly LOCK_WAIT_SECONDS=10
fi

# Only files without secrets are copied from Git into the stack directory.
readonly DEPLOY_ITEMS=(
    .env.example
    compose.yml
    compose
    configs
)

readonly SJV_DOMAIN="sjv.serveftp.org"
readonly MQTT_HOSTNAME_ALLOWED=(
    "sjv.serveftp.org"
    "sjv-mqtt.serveftp.org"
)

readonly NETWORK_PROXY="sjv-proxy"
readonly NETWORK_INTERNAL="sjv-internal"
readonly NETWORK_MQTT="sjv-mqtt"
readonly NETWORK_EGRESS="sjv-egress"

# Networks already used on the VPS (incusbr0, wg1 and the other WireGuard
# tunnels) and the Docker default bridge. Stack subnets must not overlap them.
readonly RESERVED_SUBNETS=(
    "10.10.10.0/24"
    "10.100.100.0/24"
    "10.110.100.0/24"
    "10.120.100.0/24"
    "172.17.0.0/16"
)

readonly TRAEFIK_ADMIN_PORT="8443"
# Traefik rotates traefik.log itself. Sizes are megabytes and days.
readonly TRAEFIK_LOG_MAX_SIZE_MB=20
readonly TRAEFIK_LOG_MAX_AGE_DAYS=14
readonly TRAEFIK_LOG_MAX_BACKUPS=14
# access.log has no built-in rotation. The script keeps this many gzip copies.
readonly ACCESS_LOG_ROTATE_KEEP=14
readonly ACCESS_LOG_ROTATE_MIN_BYTES=$((20 * 1024 * 1024))
readonly ACCESS_LOG_ROTATE_MAX_AGE=86400
readonly TRAEFIK_CONTAINER="sjv-traefik"
readonly CROWDSEC_CONTAINER="sjv-crowdsec"
readonly CROWDSEC_BOUNCER_NAME="sjv-traefik"
readonly BOUNCER_KEY_FILE="${TRAEFIK_DIR}/crowdsec/BOUNCER_KEY_${CROWDSEC_BOUNCER_NAME}"
readonly APP_BACKEND_URL="http://sjv-backend:8000"
readonly APP_WEB_URL="http://sjv-web:8080"
readonly NETWORK_LABEL="com.infrastructure-sjv.managed"
readonly NETWORK_ROLE_LABEL="com.infrastructure-sjv.role"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    readonly COLOR_RED="\033[0;31m"
    readonly COLOR_GREEN="\033[0;32m"
    readonly COLOR_YELLOW="\033[1;33m"
    readonly COLOR_BLUE="\033[0;34m"
    readonly COLOR_RESET="\033[0m"
else
    readonly COLOR_RED=""
    readonly COLOR_GREEN=""
    readonly COLOR_YELLOW=""
    readonly COLOR_BLUE=""
    readonly COLOR_RESET=""
fi
