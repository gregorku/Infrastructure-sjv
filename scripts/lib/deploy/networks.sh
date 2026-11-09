#!/usr/bin/env bash
# Creates the four project networks. An existing network is kept only when
# this project labeled it and its address plan already matches. Foreign
# networks are never changed or removed.

deploy_network_internal_flag() {
    case "$1" in
        sjv-internal) printf '%s\n' yes ;;
        sjv-proxy|sjv-mqtt|sjv-egress) printf '%s\n' no ;;
        *) return 1 ;;
    esac
}

deploy_ensure_one_network() {
    local name="$1" subnet="$2" gateway="$3" internal="$4"
    local managed role existing_subnet existing_gateway existing_internal other other_subnet
    docker_require_managed_name "${name}"
    if docker_network_exists "${name}"; then
        managed="$(docker_network_label "${name}" "${NETWORK_LABEL}")"
        role="$(docker_network_label "${name}" "${NETWORK_ROLE_LABEL}")"
        if [[ "${managed}" != true || "${role}" != "${name}" ]]; then
            fail "Docker network ${name} already exists and is not managed by ${PROJECT_NAME}. It was not changed."
        fi
        existing_subnet="$(docker_network_subnet "${name}")"
        existing_gateway="$(docker_network_gateway "${name}")"
        existing_internal="$(docker_network_internal "${name}")"
        [[ "${existing_subnet}" == "${subnet}" ]] \
            || fail "Docker network ${name} already uses ${existing_subnet}, not ${subnet}. It was not changed."
        [[ "${existing_gateway}" == "${gateway}" ]] \
            || fail "Docker network ${name} gateway is ${existing_gateway}, not ${gateway}. It was not changed."
        [[ "${existing_internal}" == "${internal}" ]] \
            || fail "Docker network ${name} internal flag is ${existing_internal}, expected ${internal}. It was not changed."
        ok "Docker network ${name} already matches ${subnet}."
        return 0
    fi
    while IFS= read -r other; do
        [[ -n "${other}" && "${other}" != "${name}" ]] || continue
        other_subnet="$(docker_network_subnet "${other}" 2>/dev/null || true)"
        [[ -n "${other_subnet}" ]] || continue
        if env_cidr_overlaps "${subnet}" "${other_subnet}"; then
            fail "Refusing to create ${name} ${subnet}: it overlaps existing network ${other} ${other_subnet}."
        fi
    done < <(docker_network_ls_names)
    docker_network_create "${name}" "${subnet}" "${gateway}" "${internal}"
    ok "Docker network ${name} created."
}

deploy_ensure_networks() {
    print_section "Docker networks"
    local name subnet gateway internal
    local -a names=(sjv-proxy sjv-internal sjv-mqtt sjv-egress)
    for name in "${names[@]}"; do
        case "${name}" in
            sjv-proxy)
                subnet="${RUNTIME_ENV[DOCKER_PROXY_SUBNET]}"
                gateway="${RUNTIME_ENV[DOCKER_PROXY_GATEWAY]}"
                ;;
            sjv-internal)
                subnet="${RUNTIME_ENV[DOCKER_INTERNAL_SUBNET]}"
                gateway="${RUNTIME_ENV[DOCKER_INTERNAL_GATEWAY]}"
                ;;
            sjv-mqtt)
                subnet="${RUNTIME_ENV[DOCKER_MQTT_SUBNET]}"
                gateway="${RUNTIME_ENV[DOCKER_MQTT_GATEWAY]}"
                ;;
            sjv-egress)
                subnet="${RUNTIME_ENV[DOCKER_EGRESS_SUBNET]}"
                gateway="${RUNTIME_ENV[DOCKER_EGRESS_GATEWAY]}"
                ;;
        esac
        internal="$(deploy_network_internal_flag "${name}")" \
            || fail "No internal flag is defined for ${name}."
        deploy_ensure_one_network "${name}" "${subnet}" "${gateway}" "${internal}"
    done
}

deploy_assert_own_containers() {
    local name project
    for name in "${TRAEFIK_CONTAINER}" "${CROWDSEC_CONTAINER}"; do
        if ! project="$(docker_container_project "${name}" 2>/dev/null)"; then
            continue
        fi
        [[ "${project}" == "${STACK_NAME}" ]] \
            || fail "Container ${name} belongs to compose project ${project:-<none>}. It was not changed."
    done
}
