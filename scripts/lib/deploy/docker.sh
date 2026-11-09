#!/usr/bin/env bash
# The only file allowed to invoke docker. Every call is a fixed subcommand
# against this project's networks and the two containers sjv-traefik and
# sjv-crowdsec. Nothing here removes a network, a volume or another project.

docker_require_managed_name() {
    case "$1" in
        sjv-proxy|sjv-internal|sjv-mqtt|sjv-egress) ;;
        *) fail "Refusing to touch Docker network ${1}." ;;
    esac
}

docker_require_service() {
    case "$1" in
        sjv-traefik|sjv-crowdsec) ;;
        *) fail "Refusing to touch container ${1}." ;;
    esac
}

docker_network_exists() {
    docker_require_managed_name "$1"
    docker network inspect "$1" >/dev/null 2>&1
}

docker_network_ls_names() {
    docker network ls --format '{{.Name}}'
}

docker_network_subnet() {
    docker network inspect --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$1"
}

docker_network_gateway() {
    docker network inspect --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' "$1"
}

docker_network_internal() {
    local value
    value="$(docker network inspect --format '{{.Internal}}' "$1")"
    if [[ "${value}" == true ]]; then
        printf '%s\n' yes
    else
        printf '%s\n' no
    fi
}

docker_network_label() {
    local name="$1" key="$2"
    docker network inspect --format "{{index .Labels \"${key}\"}}" "${name}"
}

docker_network_create() {
    local name="$1" subnet="$2" gateway="$3" internal="$4"
    docker_require_managed_name "${name}"
    if [[ "${internal}" == yes ]]; then
        docker network create --driver bridge --internal \
            --subnet "${subnet}" --gateway "${gateway}" \
            --label "${NETWORK_LABEL}=true" \
            --label "${NETWORK_ROLE_LABEL}=${name}" \
            "${name}" >/dev/null
    else
        docker network create --driver bridge \
            --subnet "${subnet}" --gateway "${gateway}" \
            --label "${NETWORK_LABEL}=true" \
            --label "${NETWORK_ROLE_LABEL}=${name}" \
            "${name}" >/dev/null
    fi
}

docker_container_project() {
    docker_require_service "$1"
    docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$1"
}

docker_exec() {
    docker_require_service "$1"
    docker exec "$@"
}

docker_exec_timeout() {
    local seconds="$1"
    shift
    docker_require_service "$1"
    command -v timeout >/dev/null 2>&1 || fail "Required command not found: timeout."
    timeout -k 1 "${seconds}" docker exec "$@"
}

docker_container_running() {
    docker_require_service "$1"
    docker inspect -f '{{.State.Running}}' "$1"
}

docker_container_started() {
    docker_require_service "$1"
    docker inspect -f '{{.State.StartedAt}}' "$1"
}

docker_restart() {
    docker_require_service "$1"
    docker restart "$1" >/dev/null
}

# Compose is always pointed at this stack. Callers pass only "up -d" and the
# service names; they cannot select another project from this function.
docker_cli_available() {
    command -v docker >/dev/null 2>&1 || return 1
    docker compose version >/dev/null 2>&1
}

docker_compose() {
    [[ "${SJV_TEST_MODE}" -eq 0 ]] || fail "Test mode cannot run docker compose."
    case "${1:-}" in
        up) ;;
        *) fail "Refusing docker compose ${1:-<empty>}." ;;
    esac
    docker compose \
        --project-name "${STACK_NAME}" \
        --project-directory "${STACK_DIR}" \
        -f "${STACK_DIR}/compose.yml" \
        "$@"
}

# Read-only resolution. It does not create containers or networks.
docker_compose_config() {
    docker compose \
        --project-directory "${STACK_DIR}" \
        -f "${STACK_DIR}/compose.yml" \
        config
}
