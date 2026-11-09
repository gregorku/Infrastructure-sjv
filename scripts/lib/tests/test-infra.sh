#!/usr/bin/env bash
# Traefik, CrowdSec and network tests. Docker is not contacted. Files stay
# inside this run's .test-tmp directory.
# shellcheck disable=SC2016

infra_reset_base() {
    [[ "${T_BASE}" == "${T_RUN_DIR}/base" && ! -L "${T_BASE}" ]] || fail "Refusing to reset an unexpected test base."
    if [[ -d "${T_BASE}" ]]; then
        find "${T_BASE}" -mindepth 1 -delete
    else
        mkdir -m 755 "${T_BASE}"
    fi
}

test_infra_repository() {
    print_section "Compose and configuration files"
    local hits
    hits="$(grep -R -n --exclude-dir=.git --exclude=render.sh --exclude=test-infra.sh --exclude=test-static.sh \
        '/var/run/docker.sock' "${REPO_ROOT}/compose" "${REPO_ROOT}/compose.yml" "${REPO_ROOT}/configs" "${REPO_ROOT}/scripts" "${REPO_ROOT}/.env.example" || true)"
    t_check "docker.sock is not referenced" test -z "${hits}"
    [[ -z "${hits}" ]] || printf '    %s\n' "${hits}"
    hits="$(grep -n '^BOUNCER' "${REPO_ROOT}/.env.example" "${REPO_ROOT}/scripts/lib/env/policy.sh" || true)"
    t_check "the bouncer key is not an environment variable" test -z "${hits}"
    t_check "the git admin compose file publishes no port" grep -q '^services: {}$' "${REPO_ROOT}/compose/15-traefik-admin-port.yml"
    local internal proxy mqtt egress address
    internal="$(deploy_network_internal_flag sjv-internal)"
    proxy="$(deploy_network_internal_flag sjv-proxy)"
    mqtt="$(deploy_network_internal_flag sjv-mqtt)"
    egress="$(deploy_network_internal_flag sjv-egress)"
    t_check "sjv-internal is the only internal network" \
        test "${internal}${proxy}${mqtt}${egress}" = "yesnonono"
    address="$(env_address_after_gateway 172.30.10.0/24 172.30.10.1)"
    t_check "Traefik follows the proxy gateway" test "${address}" = "172.30.10.2"
    if env_address_after_gateway 172.30.10.0/24 172.30.10.254 >/dev/null; then
        t_fail "a broadcast Traefik address was accepted"
    else
        t_pass "a broadcast Traefik address is rejected"
    fi
}

test_infra_bouncer_rules() {
    print_section "Bouncer decisions"
    local action raw
    action="$(post_deploy_crowdsec_action valid yes 200)"
    t_check "a working key is kept" test "${action}" = keep
    action="$(post_deploy_crowdsec_action missing no "")"
    t_check "a missing key creates a bouncer" test "${action}" = create-new
    action="$(post_deploy_crowdsec_action invalid yes 200)"
    t_check "an invalid key is refused" test "${action}" = refuse-invalid
    action="$(post_deploy_crowdsec_action valid yes 403)"
    t_check "a rejected stored key repairs only the project bouncer" test "${action}" = repair-existing
    t_check "only the project bouncer name can be deleted" post_deploy_deletable_bouncer "${CROWDSEC_BOUNCER_NAME}"
    if post_deploy_deletable_bouncer "${CROWDSEC_BOUNCER_NAME}-other"; then
        t_fail "a longer bouncer name was deletable"
    else
        t_pass "a longer bouncer name is not deletable"
    fi
    raw=$'name,ip\nsjv-traefik-other,10.0.0.2'
    if printf '%s\n' "${raw}" | post_deploy_raw_has_bouncer "${CROWDSEC_BOUNCER_NAME}"; then
        t_fail "a bouncer prefix matched ${CROWDSEC_BOUNCER_NAME}"
    else
        t_pass "a bouncer prefix does not match"
    fi
    raw=$'sjv-traefik,10.0.0.2,validated'
    if printf '%s\n' "${raw}" | post_deploy_raw_has_bouncer "${CROWDSEC_BOUNCER_NAME}"; then
        t_pass "the exact bouncer name matches"
    else
        t_fail "the exact bouncer name was missed"
    fi
}

test_infra_networks() {
    print_section "Docker network plan"
    local created="${T_RUN_DIR}/networks-created"
    rm -f "${created}"

    # shellcheck disable=SC2329 # passed to t_expect_ok by name
    infra_plan_create() {
        fixture_valid_env RUNTIME_ENV
        docker_network_exists() { return 1; }
        docker_network_ls_names() { printf '%s\n' bridge; }
        docker_network_subnet() {
            [[ "$1" == bridge ]] && printf '%s\n' "172.17.0.0/16"
        }
        docker_network_create() { printf '%s %s %s %s\n' "$@" >> "${created}"; }
        deploy_ensure_networks
    }
    t_expect_ok "missing project networks are created" infra_plan_create
    t_check "sjv-internal is created with --internal and the others are not" \
        bash -c '[[ "$(cat "$1")" == "$(printf "%s\n" "sjv-proxy 172.30.10.0/24 172.30.10.1 no" "sjv-internal 172.30.11.0/24 172.30.11.1 yes" "sjv-mqtt 172.30.12.0/24 172.30.12.1 no" "sjv-egress 172.30.13.0/24 172.30.13.1 no")" ]]' _ "${created}"

    # shellcheck disable=SC2329 # passed to t_expect_fail by name
    infra_plan_foreign() {
        fixture_valid_env RUNTIME_ENV
        docker_network_exists() { return 0; }
        docker_network_label() { printf '\n'; }
        docker_network_create() { printf '%s\n' created >> "${created}"; }
        deploy_ensure_networks
    }
    : > "${created}"
    t_expect_fail "a foreign network with the project name is refused" "not managed" infra_plan_foreign
    t_check "a foreign network was not recreated" test ! -s "${created}"

    # shellcheck disable=SC2329 # passed to t_expect_fail by name
    infra_plan_overlap() {
        fixture_valid_env RUNTIME_ENV
        docker_network_exists() { return 1; }
        docker_network_ls_names() { printf '%s\n' foreign; }
        docker_network_subnet() { [[ "$1" == foreign ]] && printf '%s\n' "172.30.10.0/24"; }
        docker_network_create() { printf '%s\n' created >> "${created}"; }
        deploy_ensure_networks
    }
    : > "${created}"
    t_expect_fail "an overlapping existing network blocks creation" "overlaps existing network" infra_plan_overlap
    t_check "an overlapping plan creates nothing" test ! -s "${created}"

    # shellcheck disable=SC2329 # passed to t_expect_ok by name
    infra_plan_keep() {
        fixture_valid_env RUNTIME_ENV
        docker_network_exists() { return 0; }
        docker_network_label() {
            if [[ "$2" == "${NETWORK_LABEL}" ]]; then
                printf '%s\n' true
            else
                printf '%s\n' "$1"
            fi
        }
        docker_network_subnet() {
            case "$1" in
                sjv-proxy) printf '%s\n' "172.30.10.0/24" ;;
                sjv-internal) printf '%s\n' "172.30.11.0/24" ;;
                sjv-mqtt) printf '%s\n' "172.30.12.0/24" ;;
                sjv-egress) printf '%s\n' "172.30.13.0/24" ;;
            esac
        }
        docker_network_gateway() {
            case "$1" in
                sjv-proxy) printf '%s\n' "172.30.10.1" ;;
                sjv-internal) printf '%s\n' "172.30.11.1" ;;
                sjv-mqtt) printf '%s\n' "172.30.12.1" ;;
                sjv-egress) printf '%s\n' "172.30.13.1" ;;
            esac
        }
        docker_network_internal() {
            if [[ "$1" == sjv-internal ]]; then
                printf '%s\n' yes
            else
                printf '%s\n' no
            fi
        }
        docker_network_create() { printf '%s\n' created >> "${created}"; }
        deploy_ensure_networks
    }
    : > "${created}"
    t_expect_ok "a matching managed network is kept" infra_plan_keep
    t_check "a matching network is not created again" test ! -s "${created}"
    t_expect_fail "an unrelated network name is refused" "Refusing to touch Docker network" \
        docker_require_managed_name somebody-else
}

test_infra_render() {
    print_section "Rendered runtime"
    local stack env_file dynamic git_admin before
    infra_reset_base
    stack="${T_BASE}/stacks/infrastructure-sjv"
    env_file="${stack}/.env"
    dynamic="${stack}/runtime/traefik/dynamic"
    git_admin="$(cksum "${REPO_ROOT}/compose/15-traefik-admin-port.yml")"
    run_script init.sh
    t_check "init.sh succeeds with the compose tree" test "${T_RC}" -eq 0
    run_script update-env.sh
    t_check "update-env.sh succeeds" test "${T_RC}" -eq 0
    fill_fixture_values "${env_file}"
    run_script deploy.sh
    t_check "deploy.sh without --render-only is refused in test mode" \
        bash -c '(( $1 != 0 )) && [[ "$2" == *"cannot create Docker networks"* ]]' _ "${T_RC}" "${T_OUT}"
    t_check "a refused deploy creates no runtime directory" test ! -e "${stack}/runtime"
    run_script deploy.sh --render-only
    if (( T_RC == 0 )); then
        t_pass "deploy.sh --render-only succeeds"
    else
        t_fail "deploy.sh --render-only succeeds (exit ${T_RC}): ${T_OUT##*$'\n'}"
    fi
    t_check "render says Docker was not called" t_contains "${T_OUT}" "Docker was not called"
    t_check "Traefik static config has no Docker socket" test -z "$(grep -n 'docker.sock' "${stack}/runtime/traefik/traefik.yml" || true)"
    t_check "Traefik uses the file provider" grep -q 'directory: /etc/traefik/dynamic' "${stack}/runtime/traefik/traefik.yml"
    t_check "the Docker provider is absent" bash -c '! grep -q "^  docker:" "$1"' _ "${stack}/runtime/traefik/traefik.yml"
    t_check "the API is not insecure" grep -q 'insecure: false' "${stack}/runtime/traefik/traefik.yml"
    t_check "TLS 1.2 is the minimum" grep -q 'minVersion: VersionTLS12' "${dynamic}/tls.yml"
    t_check "the allowlist is rendered from the fixture" grep -q '10.66.0.2/32' "${dynamic}/ip-allowlist.yml"
    t_check "future API and web routes are present" grep -q 'http://sjv-backend:8000' "${dynamic}/app.yml"
    t_check "the bouncer middleware waits for the key file" test ! -e "${dynamic}/crowdsec.yml"
    t_check "no dashboard router without a password file" test ! -e "${dynamic}/dashboard.yml"
    t_check "no MQTT certificate router in local TLS mode" test ! -e "${dynamic}/mqtt-cert.yml"
    t_check "Traefik's proxy address is the gateway plus one" \
        bash -c '[[ "$(cat "$1")" == 172.30.10.2 ]]' _ "${stack}/runtime/traefik-proxy-address"
    t_check "the git admin compose file was not rewritten" \
        bash -c '[[ "$(cksum "$1")" == "$2" ]]' _ \
        "${REPO_ROOT}/compose/15-traefik-admin-port.yml" "${git_admin}"
    t_check "render leaves no temporary file" \
        bash -c '[[ -z "$(find "$1" -name "*.tmp.*" -print -quit)" ]]' _ "${stack}/runtime"
    before="$(cksum "${stack}/runtime/traefik/traefik.yml")"
    run_script deploy.sh --render-only
    t_check "a second render succeeds" test "${T_RC}" -eq 0
    t_check "a second render keeps the static Traefik file" \
        bash -c '[[ "$(cksum "$1")" == "$2" ]]' _ "${stack}/runtime/traefik/traefik.yml" "${before}"
}

test_infra_key_and_compose() {
    print_section "Bouncer key file"
    local stack key_file dynamic fixture git_admin
    stack="${T_BASE}/stacks/infrastructure-sjv"
    key_file="${T_BASE}/infrastructure-sjv/traefik/crowdsec/BOUNCER_KEY_sjv-traefik"
    dynamic="${stack}/runtime/traefik/dynamic"
    fixture="FIXTUREKEY0123456789abcd"
    printf '%s\n' "keep-me" > "${T_BASE}/infrastructure-sjv/traefik/crowdsec/.bouncer-key.keep"
    chmod 600 "${T_BASE}/infrastructure-sjv/traefik/crowdsec/.bouncer-key.keep"
    t_run env NO_COLOR=1 SJV_TEST_BASE_DIR="${T_BASE}" bash --noprofile --norc -c '
        set -Eeuo pipefail
        source "$1/scripts/config.sh"
        source "$1/scripts/lib/logging.sh"
        source "$1/scripts/lib/common.sh"
        source "$1/scripts/lib/deploy/crowdsec.sh"
        post_deploy_write_bouncer_key "$2"
    ' _ "${REPO_ROOT}" "${fixture}"
    t_check "the bouncer key file is written" test "${T_RC}" -eq 0
    t_check "the command output does not contain the key" t_not_contains "${T_OUT}" "${fixture}"
    t_check "the key file is mode 600" test "$(stat -c %a "${key_file}")" = 600
    printf '%s\n' "${fixture}" > "${T_RUN_DIR}/expected-key"
    t_check "the key file matches the fixture" cmp -s "${T_RUN_DIR}/expected-key" "${key_file}"
    t_check "writing the key removes only its own temporary file" test -f "${T_BASE}/infrastructure-sjv/traefik/crowdsec/.bouncer-key.keep"
    t_check "no bouncer temporary file remains" \
        bash -c '[[ -z "$(find "$1" -name ".bouncer-key.??????" -print -quit)" ]]' _ "${T_BASE}/infrastructure-sjv/traefik/crowdsec"
    run_script deploy.sh --render-only
    t_check "render attaches the bouncer after the key exists" test "${T_RC}" -eq 0
    t_check "the bouncer middleware points at the key file" \
        grep -q 'BOUNCER_KEY_sjv-traefik' "${dynamic}/crowdsec.yml"
    t_check "the app chain includes CrowdSec" grep -q '          - crowdsec' "${dynamic}/chains.yml"
    t_check "LAPI stays on the compose service name" grep -q 'crowdsec:8080' "${dynamic}/crowdsec.yml"

    if docker_cli_available; then
        t_run env NO_COLOR=1 SJV_TEST_BASE_DIR="${T_BASE}" \
            TRAEFIK_PROXY_ADDRESS="$(<"${stack}/runtime/traefik-proxy-address")" \
            bash --noprofile --norc -c '
                set -Eeuo pipefail
                source "$1/scripts/config.sh"
                source "$1/scripts/lib/logging.sh"
                source "$1/scripts/lib/deploy/docker.sh"
                docker_compose_config
            ' _ "${REPO_ROOT}"
        if (( T_RC == 0 )) && t_not_contains "${T_OUT}" "/var/run/docker.sock"; then
            t_pass "docker compose config accepts the rendered stack"
        else
            t_fail "docker compose config failed or exposed the socket (exit ${T_RC})"
            printf '    %s\n' "${T_OUT##*$'\n'}"
        fi
    else
        t_skip "compose config was not run because the Docker CLI is not installed"
    fi
    git_admin="$(cksum "${REPO_ROOT}/compose/15-traefik-admin-port.yml")"
    t_check "compose config left the git admin file unchanged" \
        bash -c '[[ "$(cksum "$1")" == "$2" ]]' _ "${REPO_ROOT}/compose/15-traefik-admin-port.yml" "${git_admin}"
    t_check "no /docker-data directory was created" test ! -e /docker-data
}

run_infra_tests() {
    print_header "Traefik and CrowdSec"
    test_infra_repository
    test_infra_bouncer_rules
    test_infra_networks
    test_infra_render
    test_infra_key_and_compose
}
