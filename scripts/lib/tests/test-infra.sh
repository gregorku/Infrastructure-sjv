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
    t_check "Traefik is pinned to the supported 3.7 release" \
        grep -qx 'TRAEFIK_IMAGE=docker.io/library/traefik:v3.7.17@sha256:f4bb143d1135a579b630ed491e17ec50f6f7c9c6a30585ff3d385471d2a86f5a' "${REPO_ROOT}/.env.example"
    t_check "CrowdSec is pinned to v1.8.2 and its index digest" \
        grep -qx 'CROWDSEC_IMAGE=docker.io/crowdsecurity/crowdsec:v1.8.2@sha256:65b74942f7e7ed5c60fde4ac15fc4ba715904c398c8b16dd451f4907d90347d4' "${REPO_ROOT}/.env.example"
    t_check "the bouncer plugin version and catalog hash are pinned" \
        bash -c 'grep -qx "CROWDSEC_BOUNCER_PLUGIN=v1.8.1" "$1" && grep -qx "CROWDSEC_BOUNCER_PLUGIN_HASH=1c63fab00b5c777fc02dc657ce24557c1e7f8548af4fd13fc4bfd8f0aa91f12d" "$1"' _ "${REPO_ROOT}/.env.example"
    t_check "PostgreSQL 19.0 is pinned by tag and index digest" \
        grep -qx 'POSTGRES_IMAGE=docker.io/library/postgres:19.0@sha256:bb6e70add742cd868fb62cb3b2f67d1dd2bdd2b65a521e778420748753687c60' "${REPO_ROOT}/.env.example"
    t_check "pgBackRest is pinned to 2.60.1" \
        grep -qx 'PGBACKREST_VERSION=2.60.1' "${REPO_ROOT}/.env.example"
    t_check "CrowdSec healthcheck authenticates to LAPI" \
        grep -q 'cscli lapi status' "${REPO_ROOT}/compose/20-crowdsec.yml"
    t_check "Traefik drops capabilities and keeps only bind" \
        bash -c 'grep -q "cap_drop:" "$1" && grep -q "NET_BIND_SERVICE" "$1" && grep -q "read_only: true" "$1" && grep -q "/plugins-storage" "$1"' _ "${REPO_ROOT}/compose/10-traefik.yml"
    t_check "CrowdSec drops every capability" \
        grep -q 'cap_drop:' "${REPO_ROOT}/compose/20-crowdsec.yml"
    t_check "Traefik is not attached to the egress network" \
        bash -c '! grep -q "sjv-egress" "$1"' _ "${REPO_ROOT}/compose/10-traefik.yml"
    t_check "CrowdSec is not attached to the proxy network" \
        bash -c '! grep -q "sjv-proxy" "$1"' _ "${REPO_ROOT}/compose/20-crowdsec.yml"
    t_check "CrowdSec does not add a capability back" \
        bash -c '! grep -q "cap_add:" "$1"' _ "${REPO_ROOT}/compose/20-crowdsec.yml"
    t_check "Traefik still waits until CrowdSec is healthy" \
        grep -q 'condition: service_healthy' "${REPO_ROOT}/compose/10-traefik.yml"
    t_check "CrowdSec still tails the live access log" \
        grep -qx '  - /logs/access.log' "${REPO_ROOT}/configs/crowdsec/acquis.yaml"
    t_check "the log timer proposal points at the rotation script" \
        grep -q 'scripts/rotate-traefik-logs.sh' "${REPO_ROOT}/ops/systemd/sjv-traefik-logrotate.service"
    t_check "the log timer proposal is hourly" \
        grep -qx 'OnCalendar=hourly' "${REPO_ROOT}/ops/systemd/sjv-traefik-logrotate.timer"
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
    t_check "publish without a dashboard password is refused" \
        bash -c '(( $1 != 0 )) && [[ "$2" == *"dashboard password file is missing"* ]]' _ "${T_RC}" "${T_OUT}"
    t_check "a refused publish leaves the stack admin file without a host port" \
        bash -c '! grep -q "8443:8443" "$1"' _ "${stack}/compose/15-traefik-admin-port.yml"
    t_check "a refused publish does not rewrite the git admin file" \
        bash -c '[[ "$(cksum "$1")" == "$2" ]]' _ \
        "${REPO_ROOT}/compose/15-traefik-admin-port.yml" "${git_admin}"
    set_env_value "${env_file}" TRAEFIK_ADMIN_PUBLISH ""
    run_script deploy.sh --render-only
    if (( T_RC == 0 )); then
        t_pass "deploy.sh --render-only succeeds"
    else
        t_fail "deploy.sh --render-only succeeds (exit ${T_RC}): ${T_OUT##*$'\n'}"
    fi
    t_check "render says Docker was not called" t_contains "${T_OUT}" "Docker was not called"
    t_check "Traefik static config has no Docker socket" test -z "$(grep -n 'docker.sock' "${stack}/runtime/traefik/traefik.yml" || true)"
    t_check "Traefik uses the file provider" grep -q 'directory: /etc/traefik/dynamic' "${stack}/runtime/traefik/traefik.yml"
    t_check "traefik.log rotation limits are rendered" \
        bash -c 'grep -q "maxSize: 20" "$1" && grep -q "maxAge: 14" "$1" && grep -q "maxBackups: 14" "$1" && grep -q "compress: true" "$1"' _ "${stack}/runtime/traefik/traefik.yml"
    t_check "the plugin catalog hash is rendered" \
        grep -q 'hash: 1c63fab00b5c777fc02dc657ce24557c1e7f8548af4fd13fc4bfd8f0aa91f12d' "${stack}/runtime/traefik/traefik.yml"
    t_check "the Docker provider is absent" bash -c '! grep -q "^  docker:" "$1"' _ "${stack}/runtime/traefik/traefik.yml"
    t_check "the API is not insecure" grep -q 'insecure: false' "${stack}/runtime/traefik/traefik.yml"
    t_check "TLS 1.2 is the minimum" grep -q 'minVersion: VersionTLS12' "${dynamic}/tls.yml"
    t_check "the allowlist is rendered from the fixture" grep -q '10.66.0.2/32' "${dynamic}/ip-allowlist.yml"
    t_check "future API and web routes are present" grep -q 'http://sjv-backend:8000' "${dynamic}/app.yml"
    t_check "the site router uses the runtime domain" grep -q 'Host(`app.example.net`)' "${dynamic}/app.yml"
    t_check "a distinct MQTT hostname gets a certificate router" \
        grep -q 'Host(`mqtt.example.net`)' "${dynamic}/mqtt-cert.yml"
    t_check "the bouncer middleware waits for the key file" test ! -e "${dynamic}/crowdsec.yml"
    t_check "no dashboard router without a password file" test ! -e "${dynamic}/dashboard.yml"
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

    set_env_value "${env_file}" MQTT_HOSTNAME "app.example.net"
    run_script deploy.sh --render-only
    t_check "a shared site and MQTT name renders again" test "${T_RC}" -eq 0
    t_check "a shared host name has no separate MQTT certificate" test ! -e "${dynamic}/mqtt-cert.yml"

    set_env_value "${env_file}" MQTT_HOSTNAME "mqtt.example.net"
    set_env_value "${env_file}" TRAEFIK_TLS_MODE "local"
    set_env_value "${env_file}" PROXY_PROTOCOL_MODE "local"
    set_env_value "${env_file}" PROXY_PROTOCOL_TRUSTED_IPS ""
    run_script deploy.sh --render-only
    t_check "local TLS mode renders again" test "${T_RC}" -eq 0
    t_check "local TLS mode has no MQTT certificate router" test ! -e "${dynamic}/mqtt-cert.yml"
}

test_infra_key_and_compose() {
    print_section "Bouncer key file"
    local stack key_file dynamic fixture git_admin docker_data_before
    docker_data_before="$(docker_data_snapshot)"
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
    t_check "the /docker-data path is unchanged" \
        bash -c '[[ "$1" == "$2" ]]' _ "${docker_data_before}" "$(docker_data_snapshot)"
}

test_infra_log_rotation() {
    print_section "Access log rotation"
    local logs="${T_BASE}/infrastructure-sjv/traefik/logs" live foreign marker inode mode owner
    local fake="${T_RUN_DIR}/fakebin" archive_count
    if log_rotate_due 0 0 100 1; then
        t_fail "an empty access log was eligible for rotation"
    else
        t_pass "an empty access log is not rotated"
    fi
    if log_rotate_due 10 1000 1000 0; then
        t_fail "a fresh small access log was eligible"
    else
        t_pass "a fresh small access log waits"
    fi
    if log_rotate_due 10 1000 $((1000 + ACCESS_LOG_ROTATE_MAX_AGE)) 0; then
        t_pass "an old access log is eligible"
    else
        t_fail "an old access log was not eligible"
    fi
    if log_rotate_due "${ACCESS_LOG_ROTATE_MIN_BYTES}" 1000 1000 0; then
        t_pass "a large access log is eligible"
    else
        t_fail "a large access log was not eligible"
    fi

    infra_reset_base
    run_script init.sh
    t_check "init creates the plugin directory" test -d "${T_BASE}/infrastructure-sjv/traefik/plugins"
    t_check "the plugin directory is mode 755" test "$(stat -c %a "${T_BASE}/infrastructure-sjv/traefik/plugins")" = 755
    live="${logs}/access.log"
    foreign="${T_BASE}/access.log"
    marker="SECRET-LOG-LINE"
    printf '%s\n' "${marker}" > "${live}"
    printf '%s\n' "keep-outside" > "${foreign}"
    inode="$(stat -c %i "${live}")"
    mode="$(stat -c %a "${live}")"
    owner="$(stat -c %u:%g "${live}")"
    run_script rotate-traefik-logs.sh
    t_check "a fresh small log is left in place" test "${T_RC}" -eq 0
    t_check "the skipped run does not mention the log line" t_not_contains "${T_OUT}" "${marker}"
    t_check "the live log still has its line" grep -qx "${marker}" "${live}"

    touch -d '25 hours ago' "${live}"
    run_script rotate-traefik-logs.sh
    t_check "an old access log rotates" test "${T_RC}" -eq 0
    t_check "rotation does not print the log line" t_not_contains "${T_OUT}" "${marker}"
    t_check "the live file keeps its inode" test "$(stat -c %i "${live}")" = "${inode}"
    t_check "the live file keeps its mode" test "$(stat -c %a "${live}")" = "${mode}"
    t_check "the live file keeps its owner" test "$(stat -c %u:%g "${live}")" = "${owner}"
    t_check "the live file is empty after copytruncate" test ! -s "${live}"
    t_check "a file outside the log directory is untouched" grep -qx 'keep-outside' "${foreign}"
    archive_count="$(find "${logs}" -maxdepth 1 -type f -name 'access.log.*.gz' | wc -l)"
    t_check "one compressed archive was written" test "${archive_count}" -eq 1
    t_check "the archive is mode 640" \
        bash -c '[[ "$(stat -c %a "$1"/access.log.*.gz)" == 640 ]]' _ "${logs}"
    t_check "the archive contains the original line" \
        bash -c 'gzip -dc "$1"/access.log.*.gz | grep -qx "$2"' _ "${logs}" "${marker}"
    t_check "no partial rotation file remains" \
        bash -c '[[ -z "$(find "$1" -name ".access-rotate.*" -print -quit)" ]]' _ "${logs}"
    t_check "traefik.log was not created by rotation" test ! -e "${logs}/traefik.log"

    run_script rotate-traefik-logs.sh --force
    t_check "a second run does not rotate an empty file" test "${T_RC}" -eq 0
    t_check "the second run keeps the single archive" \
        bash -c '[[ "$(find "$1" -maxdepth 1 -type f -name "access.log.*.gz" | wc -l)" -eq 1 ]]' _ "${logs}"

    local i
    for i in $(seq 1 16); do
        printf 'old\n' | gzip -c > "${logs}/access.log.202601$(printf '%02d' "${i}")T000000Z.gz"
        # Spread mtimes so retention order is the sequence, not the clock.
        touch -d "2026-01-${i} 00:00:00 UTC" "${logs}/access.log.202601$(printf '%02d' "${i}")T000000Z.gz"
    done
    # January has 31 days; 16 is valid. A non-matching name must survive.
    printf 'notes\n' > "${logs}/access.log.notes.gz"
    run_script rotate-traefik-logs.sh
    t_check "retention keeps fourteen archives" \
        bash -c '[[ "$(find "$1" -maxdepth 1 -type f -name "access.log.[0-9]*.gz" | wc -l)" -eq 14 ]]' _ "${logs}"
    t_check "a name that is not a rotation archive is kept" test -f "${logs}/access.log.notes.gz"

    printf '%s\n' "${marker}" > "${live}"
    mkdir -m 755 "${fake}"
    printf '%s\n' '#!/bin/sh' 'echo gzip-failed >&2' 'exit 1' > "${fake}/gzip"
    chmod 755 "${fake}/gzip"
    t_run env NO_COLOR=1 SJV_TEST_BASE_DIR="${T_BASE}" PATH="${fake}:${PATH}" "${REPO_ROOT}/scripts/rotate-traefik-logs.sh" --force
    t_check "a failed compression leaves the live log" \
        bash -c '(( $1 != 0 )) && grep -qx "$2" "$3"' _ "${T_RC}" "${marker}" "${live}"
    t_check "a failed compression removes its temporary files" \
        bash -c '[[ -z "$(find "$1" -name ".access-rotate.*" -print -quit)" ]]' _ "${logs}"

    mv "${live}" "${logs}/access.log.real"
    ln -s access.log.real "${live}"
    run_script rotate-traefik-logs.sh --force
    t_check "a symlinked access log is refused" test "${T_RC}" -ne 0
    t_check "the symlink target was not truncated" grep -qx "${marker}" "${logs}/access.log.real"
    rm -f "${live}"
    mv "${logs}/access.log.real" "${live}"
}

# PostgreSQL 19 copies the member role's INHERIT attribute when GRANT omits it.
# SET defaults to true. Prints: member_role granted_role inherit_option set_option.
# Returns 0 only when the three backup memberships all have inherit_option true.
pgbackrest_membership_report() {
    local file="$1" line inherit_default="true" inherit_option set_option="true" roles role seen=0 bad=0
    line="$(grep -E '^CREATE ROLE pgbackrest[[:space:]]' "${file}" || true)"
    [[ -n "${line}" ]] || return 1
    [[ "${line}" == *"NOINHERIT"* ]] && inherit_default="false"
    line="$(grep -E '^GRANT[[:space:]].*[[:space:]]TO[[:space:]]pgbackrest' "${file}" | grep -F 'pg_checkpoint' || true)"
    [[ -n "${line}" ]] || return 1
    if [[ "${line}" == *"INHERIT FALSE"* ]]; then
        inherit_option="false"
    elif [[ "${line}" == *"INHERIT TRUE"* || "${line}" == *"INHERIT OPTION"* ]]; then
        inherit_option="true"
    else
        inherit_option="${inherit_default}"
    fi
    [[ "${line}" == *"SET FALSE"* ]] && set_option="false"
    roles="${line#GRANT }"
    roles="${roles%% TO pgbackrest*}"
    local IFS=','
    local -a parts=()
    read -ra parts <<< "${roles}"
    for role in "${parts[@]}"; do
        role="${role#"${role%%[![:space:]]*}"}"
        role="${role%"${role##*[![:space:]]}"}"
        [[ -n "${role}" ]] || continue
        printf '%s %s %s %s\n' pgbackrest "${role}" "${inherit_option}" "${set_option}"
        seen=$((seen + 1))
        case "${role}" in
            pg_checkpoint|pg_read_all_settings|pg_read_all_stats) ;;
            *) bad=1 ;;
        esac
        [[ "${inherit_option}" == "true" ]] || bad=1
    done
    [[ "${seen}" -eq 3 && "${bad}" -eq 0 ]]
}

# Prints the four backup EXECUTE grants, one normalized line each.
# Returns 0 only when the signatures match PostgreSQL 19.0 exactly.
pgbackrest_execute_grants() {
    local file="$1"
    awk '
        /^GRANT EXECUTE ON FUNCTION / {
            buffer = $0
            if ($0 ~ /;[[:space:]]*$/) {
                print buffer
                buffer = ""
                next
            }
            collecting = 1
            next
        }
        collecting {
            sub(/^[[:space:]]+/, "")
            buffer = buffer " " $0
            if ($0 ~ /;[[:space:]]*$/) {
                print buffer
                buffer = ""
                collecting = 0
            }
        }
    ' "${file}"
}

test_postgresql_service() {
    print_section "PostgreSQL service"
    local compose="${REPO_ROOT}/compose/40-postgresql.yml"
    local dockerfile="${REPO_ROOT}/postgresql/Dockerfile"
    local roles="${REPO_ROOT}/postgresql/docker-entrypoint-initdb.d/20-roles.sql"
    local conf="${REPO_ROOT}/postgresql/pgbackrest.conf"
    t_check "compose includes the postgresql service" \
        grep -q 'compose/40-postgresql.yml' "${REPO_ROOT}/compose.yml"
    t_check "the service is sjv-postgresql" grep -q '^  sjv-postgresql:' "${compose}"
    t_check "the build receives the pinned PostgreSQL image" \
        grep -q 'POSTGRES_IMAGE: ${POSTGRES_IMAGE:?POSTGRES_IMAGE}' "${compose}"
    t_check "the build receives the pgBackRest version" \
        grep -q 'PGBACKREST_VERSION: ${PGBACKREST_VERSION:?PGBACKREST_VERSION}' "${compose}"
    t_check "the Dockerfile has no floating PostgreSQL tag" \
        bash -c '! grep -Eq "postgres:(19|latest)([^0-9.]|$)" "$1"' _ "${dockerfile}"
    t_check "the Dockerfile requires the pgBackRest 2.60.1 tarball checksum" \
        grep -q 'PGBACKREST_SHA256=c6d8190fee982f0febdd2ca5ca112f83b4b0905ef9949e9cf64a46a6cc138026' "${dockerfile}"
    t_check "the Dockerfile keeps the official entrypoint" \
        grep -qxF 'ENTRYPOINT ["docker-entrypoint.sh"]' "${dockerfile}"
    t_check "pgBackRest 2.60.1 disables automatic expire" \
        grep -qx 'expire-auto=n' "${conf}"
    t_check "pgBackRest reads the PostgreSQL 19 data directory" \
        grep -qx 'pg1-path=/var/lib/postgresql/19/docker' "${conf}"
    t_check "the healthcheck is pg_isready" grep -q 'pg_isready' "${compose}"
    t_check "the database port is not published" \
        bash -c '! grep -Eq "^[[:space:]]*ports:" "$1"' _ "${compose}"
    t_check "PostgreSQL joins only the internal network" \
        bash -c 'grep -qx "      - sjv-internal" "$1" && ! grep -Eq "sjv-proxy|sjv-mqtt|sjv-egress" "$1"' _ "${compose}"
    t_check "PostgreSQL data uses the project data directory" \
        grep -q '${DATA_DIR}/postgresql:/var/lib/postgresql$' "${compose}"
    t_check "pgBackRest repository uses the local backup directory" \
        grep -q '${BACKUP_LOCAL_DIR}/pgbackrest:/backup/pgbackrest$' "${compose}"
    t_check "initdb enables data checksums" \
        grep -q 'POSTGRES_INITDB_ARGS: "--data-checksums"' "${compose}"
    t_check "archive mode and timeout are set on the server command" \
        bash -c 'grep -q "archive_mode=on" "$1" && grep -q "archive_timeout=60" "$1" && grep -q "archive_command=pgbackrest --stanza=sjv archive-push %p" "$1"' _ "${compose}"
    t_check "role passwords are variables and are not written into the image" \
        bash -c '! grep -E "PASSWORD[=:].*set_|PASSWORD[=:].{8,}" "$1" "$2" | grep -v "PG_.*PASSWORD" | grep -v "POSTGRES_SJV_" >/dev/null' _ "${compose}" "${roles}"
    t_check "role creation reads passwords with getenv" grep -q '\\getenv' "${roles}"
    t_check "application roles are not superusers" \
        bash -c 'grep -q "sjv_owner LOGIN PASSWORD %L NOSUPERUSER" "$1" && grep -q "sjv_api LOGIN PASSWORD %L NOSUPERUSER" "$1" && grep -q "sjv_collector LOGIN PASSWORD %L NOSUPERUSER" "$1" && grep -q "sjv_worker LOGIN PASSWORD %L NOSUPERUSER" "$1" && grep -q "sjv_maintenance LOGIN PASSWORD %L NOSUPERUSER" "$1" && grep -q "sjv_readonly LOGIN PASSWORD %L NOSUPERUSER" "$1" && ! grep -Eq "LOGIN SUPERUSER|ALTER ROLE .* SUPERUSER" "$1"' _ "${roles}"
    t_check "the backup role has no password and is not a superuser" \
        grep -qx 'CREATE ROLE pgbackrest LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;' "${roles}"
    t_check "backup memberships set INHERIT TRUE and keep the role NOINHERIT" \
        grep -qx 'GRANT pg_checkpoint, pg_read_all_settings, pg_read_all_stats TO pgbackrest WITH INHERIT TRUE;' "${roles}"
    local membership membership_sql="${REPO_ROOT}/postgresql/checks/pgbackrest-membership.sql"
    membership="$(pgbackrest_membership_report "${roles}")"
    t_check "catalog rows show inherited backup memberships" \
        bash -c '[[ "$1" == "pgbackrest pg_checkpoint true true
pgbackrest pg_read_all_settings true true
pgbackrest pg_read_all_stats true true" ]]' _ "${membership}"
    t_check "the catalog check is not executed during database init" \
        bash -c '[[ ! -e "$1/docker-entrypoint-initdb.d/pgbackrest-membership.sql" ]]' _ "${REPO_ROOT}/postgresql"
    t_check "the catalog check reads member, granted role, inherit_option and set_option" \
        bash -c 'grep -q "member_role.rolname AS member_role" "$1" && grep -q "granted_role.rolname AS granted_role" "$1" && grep -q "m.inherit_option" "$1" && grep -q "m.set_option" "$1" && grep -q "member_role.oid = m.member" "$1" && grep -q "granted_role.oid = m.roleid" "$1" && grep -q "AND m.inherit_option" "$1"' _ "${membership_sql}"
    local old_grant="${T_RUN_DIR}/pgbackrest-grant-without-inherit.sql"
    cat > "${old_grant}" <<'EOF'
CREATE ROLE pgbackrest LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
GRANT pg_checkpoint, pg_read_all_settings, pg_read_all_stats TO pgbackrest;
EOF
    if pgbackrest_membership_report "${old_grant}" >/dev/null; then
        t_fail "a grant without INHERIT TRUE is rejected for the NOINHERIT backup role"
    else
        t_pass "a grant without INHERIT TRUE is rejected for the NOINHERIT backup role"
    fi
    rm -f "${old_grant}"
    local execute_sql="${REPO_ROOT}/postgresql/checks/pgbackrest-execute.sql"
    local execute_grants expected_grants
    expected_grants=$'GRANT EXECUTE ON FUNCTION pg_catalog.pg_backup_start(text, boolean) TO pgbackrest;\nGRANT EXECUTE ON FUNCTION pg_catalog.pg_backup_stop(boolean) TO pgbackrest;\nGRANT EXECUTE ON FUNCTION pg_catalog.pg_create_restore_point(text) TO pgbackrest;\nGRANT EXECUTE ON FUNCTION pg_catalog.pg_switch_wal() TO pgbackrest;'
    execute_grants="$(pgbackrest_execute_grants "${roles}")"
    t_check "backup functions have the PostgreSQL 19 EXECUTE signatures" \
        bash -c '[[ "$1" == "$2" ]]' _ "${execute_grants}" "${expected_grants}"
    t_check "EXECUTE is not granted on every catalog function" \
        bash -c '! grep -Eq "GRANT EXECUTE ON ALL FUNCTIONS" "$1"' _ "${roles}"
    t_check "the function privilege check is not an init script" \
        bash -c '[[ ! -e "$1/docker-entrypoint-initdb.d/pgbackrest-execute.sql" ]]' _ "${REPO_ROOT}/postgresql"
    t_check "the function privilege check names all four backup functions" \
        bash -c 'grep -Fq "pg_catalog.pg_backup_start(text,boolean)" "$1" && grep -Fq "pg_catalog.pg_backup_stop(boolean)" "$1" && grep -Fq "pg_catalog.pg_create_restore_point(text)" "$1" && grep -Fq "pg_catalog.pg_switch_wal()" "$1"' _ "${execute_sql}"
    local wrong_grant="${T_RUN_DIR}/pgbackrest-wrong-execute.sql"
    cat > "${wrong_grant}" <<'EOF'
GRANT EXECUTE ON FUNCTION pg_catalog.pg_backup_start(text) TO pgbackrest;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_backup_stop(boolean) TO pgbackrest;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_create_restore_point(text) TO pgbackrest;
EOF
    if [[ "$(pgbackrest_execute_grants "${wrong_grant}")" == "${expected_grants}" ]]; then
        t_fail "a changed or missing backup function signature is rejected"
    else
        t_pass "a changed or missing backup function signature is rejected"
    fi
    rm -f "${wrong_grant}"
    t_check "the bootstrap superuser is the image user, not a second superuser" \
        bash -c 'grep -q "POSTGRES_USER: \${PG_BOOTSTRAP_USER:?PG_BOOTSTRAP_USER}" "$1" && ! grep -q "CREATE ROLE sjv_bootstrap" "$2"' _ "${compose}" "${roles}"
}

run_infra_tests() {
    print_header "Traefik and CrowdSec"
    test_infra_repository
    test_infra_bouncer_rules
    test_infra_networks
    test_infra_render
    test_infra_key_and_compose
    test_infra_log_rotation
    test_postgresql_service
}
