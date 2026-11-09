#!/usr/bin/env bash
# Unit tests of scripts/lib/env. All files live in the run directory under
# .test-tmp; values are test fixtures, not real configuration.
# shellcheck disable=SC2016,SC2034
# SC2016: snippets stay single-quoted so this process does not expand them.
# SC2034: several arrays are handed to helpers by name.

# Fills the named array with a complete, valid test configuration.
fixture_valid_env() {
    local -n fixture_ref="$1"
    local key
    fixture_ref=()
    env_parse_file "${ENV_EXAMPLE_FILE}" fixture_ref
    fixture_ref[MQTT_HOSTNAME]="sjv-mqtt.serveftp.org"
    fixture_ref[DOCKER_PROXY_SUBNET]="172.30.10.0/24"
    fixture_ref[DOCKER_PROXY_GATEWAY]="172.30.10.1"
    fixture_ref[DOCKER_INTERNAL_SUBNET]="172.30.11.0/24"
    fixture_ref[DOCKER_INTERNAL_GATEWAY]="172.30.11.1"
    fixture_ref[DOCKER_MQTT_SUBNET]="172.30.12.0/24"
    fixture_ref[DOCKER_MQTT_GATEWAY]="172.30.12.1"
    fixture_ref[DOCKER_EGRESS_SUBNET]="172.30.13.0/24"
    fixture_ref[DOCKER_EGRESS_GATEWAY]="172.30.13.1"
    fixture_ref[ADMIN_IP_ALLOWLIST]="10.66.0.2/32 192.168.50.0/24"
    for key in "${!ENV_POLICY[@]}"; do
        if [[ "${ENV_POLICY[${key}]}" == generated ]]; then
            # $ is required: this is an associative-array index, not arithmetic.
            # shellcheck disable=SC2004
            fixture_ref[${key}]="$(env_generate_secret)"
        fi
    done
}

# Usage: expect_invalid NAME EXPECTED_TEXT KEY=VALUE...
# Applies the overrides to a valid fixture and expects a validation error.
expect_invalid() {
    local name="$1" expected="$2" pair
    shift 2
    local -A cfg=()
    fixture_valid_env cfg
    for pair in "$@"; do
        cfg["${pair%%=*}"]="${pair#*=}"
    done
    if env_validate cfg; then
        t_fail "rejects ${name}: accepted"
    elif ! printf '%s\n' "${ENV_ERRORS[@]}" | grep -qF -- "${expected}"; then
        t_fail "rejects ${name}: expected '${expected}', got: ${ENV_ERRORS[*]}"
    else
        t_pass "rejects ${name}"
    fi
}

expect_valid() {
    local name="$1" pair
    shift
    local -A cfg=()
    fixture_valid_env cfg
    for pair in "$@"; do
        cfg["${pair%%=*}"]="${pair#*=}"
    done
    if env_validate cfg; then
        t_pass "accepts ${name}"
    else
        t_fail "accepts ${name}: ${ENV_ERRORS[*]}"
    fi
}

write_env_file() {
    local file="$1"
    shift
    (umask 077 && printf '%s\n' "$@" > "${file}")
}

declare -gA PARSE_SEEN=()

parse_into_scratch() {
    PARSE_SEEN=()
    env_parse_file "$1" PARSE_SEEN
}

test_env_parse() {
    print_section "Parser"
    local dir="${T_RUN_DIR}/parse"
    mkdir -m 700 "${dir}"

    write_env_file "${dir}/ok" '# comment' '' 'A_B=1' 'EMPTY=' 'SPACED=10.0.0.1/32 10.0.0.2/32'
    # Called in this shell: t_run would discard the array filled inside a subshell.
    if parse_into_scratch "${dir}/ok"; then
        t_pass "parses comments, empty values and space-separated lists"
    else
        t_fail "parses comments, empty values and space-separated lists"
    fi
    t_check "parsed values are stored" \
        test "${PARSE_SEEN[A_B]}" = 1 -a "${PARSE_SEEN[EMPTY]}" = "" -a "${PARSE_SEEN[SPACED]}" = "10.0.0.1/32 10.0.0.2/32"
    t_check "comments and blank lines are not stored" test "${#PARSE_SEEN[@]}" -eq 3

    write_env_file "${dir}/dup" 'A=1' 'A=2'
    t_expect_fail "rejects a duplicate key" "duplicate variable A" parse_into_scratch "${dir}/dup"
    write_env_file "${dir}/export" 'export A=1'
    t_expect_fail "rejects export syntax" "invalid variable name" parse_into_scratch "${dir}/export"
    write_env_file "${dir}/lower" 'a=1'
    t_expect_fail "rejects a lowercase key" "invalid variable name" parse_into_scratch "${dir}/lower"
    write_env_file "${dir}/noeq" 'JUSTTEXT'
    t_expect_fail "rejects a line without =" "not a KEY=VALUE" parse_into_scratch "${dir}/noeq"
    write_env_file "${dir}/crlf" $'A=1\r'
    t_expect_fail "rejects CRLF line endings" "carriage return" parse_into_scratch "${dir}/crlf"

    local value label expect
    for label in dollar backtick dquote squote backslash hash trailing; do
        case "${label}" in
            dollar) value='abc$HOME'; expect='contains $' ;;
            backtick) value='a`id`'; expect='backtick' ;;
            dquote) value='"quoted"'; expect='quote' ;;
            squote) value="'quoted'"; expect='quote' ;;
            backslash) value='a\b'; expect='backslash' ;;
            hash) value='abc #comment'; expect='#' ;;
            trailing) value='abc '; expect='whitespace' ;;
        esac
        write_env_file "${dir}/${label}" "A=${value}"
        t_expect_fail "rejects unsafe value (${label})" "${expect}" parse_into_scratch "${dir}/${label}"
    done

    write_env_file "${dir}/inject" "A=\$(touch ${dir}/injected)"
    t_run parse_into_scratch "${dir}/inject"
    t_check "command substitution in a value is never executed" test ! -e "${dir}/injected"

    ln -s "${dir}/ok" "${dir}/link"
    t_expect_fail "rejects a symlinked env file" "symlink" parse_into_scratch "${dir}/link"
}

test_env_net() {
    print_section "IPv4 and CIDR helpers"
    t_check "accepts 10.20.0.0/24" env_cidr_ok "10.20.0.0/24"
    local bad
    for bad in "10.20.0.0/33" "10.20.0.256/24" "10.020.0.0/24" "10.20.0.0/024" "10.20.0/24" "10.20.0.0" "abc/24"; do
        if env_cidr_ok "${bad}"; then
            t_fail "CIDR parser accepted ${bad}"
        else
            t_pass "CIDR parser rejects ${bad}"
        fi
    done
    t_check "nested subnets overlap" env_cidr_overlaps "10.20.0.0/24" "10.20.0.128/25"
    if env_cidr_overlaps "10.20.0.0/24" "10.21.0.0/24"; then
        t_fail "disjoint subnets reported as overlapping"
    else
        t_pass "disjoint subnets do not overlap"
    fi
    t_check "10.0.0.0/8 address is private" env_ip_private "10.1.2.3"
    if env_ip_private "8.8.8.8"; then t_fail "8.8.8.8 reported as private"; else t_pass "8.8.8.8 is public"; fi
}

test_env_validate() {
    print_section "Validator"
    expect_valid "a complete fixture"
    expect_valid "letsencrypt with an email" TRAEFIK_TLS_MODE=letsencrypt TRAEFIK_ACME_EMAIL=admin@example.org
    expect_valid "haproxy with a private /32" TRAEFIK_TLS_MODE=letsencrypt TRAEFIK_ACME_EMAIL=admin@example.org \
        PROXY_PROTOCOL_MODE=haproxy PROXY_PROTOCOL_TRUSTED_IPS=10.10.10.1/32
    expect_valid "a private admin publish address" TRAEFIK_ADMIN_PUBLISH=10.66.0.5:8443:8443
    expect_valid "a remote restic repository" "RESTIC_REPOSITORY=rest:https://infrastructure-sjv@10.100.100.100:8000/infrastructure-sjv/" \
        RESTIC_REST_PASSWORD=fixture-rest-password-0123
    expect_valid "a complete SMTP configuration" SMTP_HOST=smtp.example.org SMTP_USER=sjv SMTP_PASSWORD=fixture-smtp \
        MAIL_FROM=sjv@example.org SMTP_SECURITY=tls SMTP_PORT=465

    expect_invalid "a placeholder" "Placeholder is not usable: MQTT_HOSTNAME" MQTT_HOSTNAME=set_mqtt_hostname
    expect_invalid "an empty required value" "Empty variable: PG_DB" PG_DB=
    expect_invalid "an unknown MQTT host name" "MQTT_HOSTNAME must be one of" MQTT_HOSTNAME=mqtt.example.org
    expect_invalid "a changed framework path" "DATA_DIR must be" DATA_DIR=/srv/sjv
    expect_invalid "an invalid time zone" "TZ is not" "TZ=Prague"

    local -A cfg=()
    fixture_valid_env cfg
    cfg[EXTRA_VARIABLE]=1
    if env_validate cfg; then t_fail "rejects an unknown variable: accepted"
    elif printf '%s\n' "${ENV_ERRORS[@]}" | grep -q 'Unknown variable EXTRA_VARIABLE'; then t_pass "rejects an unknown variable"
    else t_fail "rejects an unknown variable: ${ENV_ERRORS[*]}"; fi
    fixture_valid_env cfg
    unset 'cfg[PG_DB]'
    if env_validate cfg; then t_fail "rejects a missing variable: accepted"
    elif printf '%s\n' "${ENV_ERRORS[@]}" | grep -q 'Missing variable: PG_DB'; then t_pass "rejects a missing variable"
    else t_fail "rejects a missing variable: ${ENV_ERRORS[*]}"; fi

    expect_invalid "a subnet that is not a network address" "must be the network address" DOCKER_PROXY_SUBNET=172.30.10.5/24
    expect_invalid "a gateway outside its subnet" "is outside DOCKER_PROXY_SUBNET" DOCKER_PROXY_GATEWAY=172.30.99.1
    expect_invalid "a gateway on the broadcast address" "broadcast" DOCKER_PROXY_GATEWAY=172.30.10.255
    expect_invalid "a /8 subnet" "prefix must be between" DOCKER_PROXY_SUBNET=10.0.0.0/8 DOCKER_PROXY_GATEWAY=10.0.0.1
    expect_invalid "a public subnet" "RFC 1918" DOCKER_PROXY_SUBNET=8.8.8.0/24 DOCKER_PROXY_GATEWAY=8.8.8.1
    expect_invalid "overlapping stack subnets" "overlap" DOCKER_EGRESS_SUBNET=172.30.10.0/25 DOCKER_EGRESS_GATEWAY=172.30.10.1
    expect_invalid "overlap with incusbr0" "10.10.10.0/24" DOCKER_MQTT_SUBNET=10.10.10.0/24 DOCKER_MQTT_GATEWAY=10.10.10.1
    expect_invalid "overlap with wg1" "10.100.100.0/24" DOCKER_MQTT_SUBNET=10.100.0.0/16 DOCKER_MQTT_GATEWAY=10.100.0.1
    expect_invalid "overlap with the Docker default bridge" "172.17.0.0/16" DOCKER_MQTT_SUBNET=172.17.5.0/24 DOCKER_MQTT_GATEWAY=172.17.5.1

    expect_invalid "an allowlist for every address" "must not allow every address" ADMIN_IP_ALLOWLIST=0.0.0.0/0
    expect_invalid "a public allowlist entry" "only private ranges" ADMIN_IP_ALLOWLIST=8.8.8.8/32
    expect_invalid "a comma-separated allowlist" "space-separated" ADMIN_IP_ALLOWLIST=10.0.0.1/32,10.0.0.2/32
    local glob_dir="${T_RUN_DIR}/glob-cwd" saved_dir joined
    mkdir -p "${glob_dir}"
    touch "${glob_dir}/not-a-cidr" "${glob_dir}/README.md"
    saved_dir="$(pwd)"
    cd "${glob_dir}" || return
    local -A glob_cfg=()
    fixture_valid_env glob_cfg
    glob_cfg[ADMIN_IP_ALLOWLIST]='*'
    if env_validate glob_cfg; then
        t_fail "an allowlist of * is rejected"
    else
        joined="$(printf '%s\n' "${ENV_ERRORS[@]}")"
        if [[ "${joined}" == *"invalid CIDR: "* && "${joined}" == *'*'* && "${joined}" != *not-a-cidr* && "${joined}" != *README.md* ]]; then
            t_pass "an allowlist of * is rejected as a CIDR, without directory names"
        else
            t_fail "an allowlist of * is rejected as a CIDR, without directory names"
            printf '    %s\n' "${joined}"
        fi
    fi
    glob_cfg[TRAEFIK_TLS_MODE]=letsencrypt
    glob_cfg[TRAEFIK_ACME_EMAIL]=admin@example.org
    glob_cfg[PROXY_PROTOCOL_MODE]=haproxy
    glob_cfg[PROXY_PROTOCOL_TRUSTED_IPS]='*'
    glob_cfg[ADMIN_IP_ALLOWLIST]='10.66.0.2/32'
    if env_validate glob_cfg; then
        t_fail "a PROXY trust value of * is rejected"
    else
        joined="$(printf '%s\n' "${ENV_ERRORS[@]}")"
        if [[ "${joined}" == *"single /32"* && "${joined}" == *'*'* && "${joined}" != *not-a-cidr* && "${joined}" != *README.md* ]]; then
            t_pass "a PROXY trust value of * is rejected, without directory names"
        else
            t_fail "a PROXY trust value of * is rejected, without directory names"
            printf '    %s\n' "${joined}"
        fi
    fi
    cd "${saved_dir}" || return
    expect_invalid "admin entrypoint on 0.0.0.0" "never 0.0.0.0" TRAEFIK_ADMIN_PUBLISH=0.0.0.0:8443:8443
    expect_invalid "admin entrypoint on a public address" "never 0.0.0.0 or a public" TRAEFIK_ADMIN_PUBLISH=8.8.8.8:8443:8443
    expect_invalid "an admin publish with another port" "must look like" TRAEFIK_ADMIN_PUBLISH=10.66.0.5:9000:8443
    expect_invalid "haproxy without letsencrypt" "requires TRAEFIK_TLS_MODE=letsencrypt" \
        PROXY_PROTOCOL_MODE=haproxy PROXY_PROTOCOL_TRUSTED_IPS=10.10.10.1/32
    expect_invalid "a PROXY trust range wider than /32" "single /32" TRAEFIK_TLS_MODE=letsencrypt TRAEFIK_ACME_EMAIL=admin@example.org \
        PROXY_PROTOCOL_MODE=haproxy PROXY_PROTOCOL_TRUSTED_IPS=10.10.10.0/24
    expect_invalid "haproxy without trusted sources" "requires PROXY_PROTOCOL_TRUSTED_IPS" TRAEFIK_TLS_MODE=letsencrypt \
        TRAEFIK_ACME_EMAIL=admin@example.org PROXY_PROTOCOL_MODE=haproxy
    expect_invalid "trusted sources in local mode" "requires an empty" PROXY_PROTOCOL_TRUSTED_IPS=10.10.10.1/32
    expect_invalid "letsencrypt with a placeholder email" "TRAEFIK_ACME_EMAIL is still a placeholder" TRAEFIK_TLS_MODE=letsencrypt
    expect_invalid "an unknown TLS mode" "TRAEFIK_TLS_MODE must be" TRAEFIK_TLS_MODE=off

    expect_invalid "a short generated secret" "PG_API_PASSWORD is shorter" PG_API_PASSWORD=short-secret-1234
    expect_invalid "a generated secret with other characters" "must use only" PG_API_PASSWORD=abcdefghijklmnopqrstuvwxyz012345%6789
    local shared
    shared="$(env_generate_secret)"
    expect_invalid "a secret shared by two accounts" "Every account needs its own secret" PG_API_PASSWORD="${shared}" PG_WORKER_PASSWORD="${shared}"
    expect_invalid "the reserved role name postgres" "reserved PostgreSQL role name" PG_API_USER=postgres
    expect_invalid "two roles with the same name" "reuses the role name" PG_WORKER_USER=sjv_api
    expect_invalid "an MQTT service account named like a device" "device account" MQTT_COLLECTOR_USER=ESP-SJV-001

    expect_invalid "a message age equal to key retention" "must be shorter than INGEST_KEY_RETENTION_DAYS" INGEST_MAX_MESSAGE_AGE_DAYS=60
    expect_invalid "a non-numeric message age" "whole number" INGEST_MAX_MESSAGE_AGE_DAYS=30d

    expect_invalid "a password inside the restic URL" "without a password in the URL" \
        "RESTIC_REPOSITORY=rest:https://infrastructure-sjv:pw@10.100.100.100:8000/infrastructure-sjv/" RESTIC_REST_PASSWORD=fixture-rest-password-0123
    expect_invalid "a restic URL for another user" "must be rest:https://infrastructure-sjv@" \
        "RESTIC_REPOSITORY=rest:https://sjv-vps@10.100.100.100:8000/infrastructure-sjv/" RESTIC_REST_PASSWORD=fixture-rest-password-0123
    expect_invalid "plain HTTP to rest-server" "must be rest:https://" \
        "RESTIC_REPOSITORY=rest:http://infrastructure-sjv@10.100.100.100:8000/infrastructure-sjv/" RESTIC_REST_PASSWORD=fixture-rest-password-0123
    expect_invalid "a rest-server password without repository" "RESTIC_REPOSITORY is empty" RESTIC_REST_PASSWORD=fixture-rest-password-0123
    expect_invalid "a short rest-server password" "at least 16" \
        "RESTIC_REPOSITORY=rest:https://infrastructure-sjv@10.100.100.100:8000/infrastructure-sjv/" RESTIC_REST_PASSWORD=short

    expect_invalid "SMTP without credentials" "SMTP_USER is required" SMTP_HOST=smtp.example.org MAIL_FROM=sjv@example.org SMTP_PASSWORD=x
    expect_invalid "unencrypted SMTP" "Unencrypted SMTP is not allowed" SMTP_SECURITY=none
    expect_invalid "SMTP credentials without a host" "SMTP_HOST is empty" SMTP_USER=sjv
    expect_invalid "a latest tag" "uses the latest tag" SMTP_HOST=smtp.example.org:latest
    expect_invalid "an unpinned Traefik image" "TRAEFIK_IMAGE must be docker.io/library/traefik" \
        TRAEFIK_IMAGE=docker.io/library/traefik:v3.7.17
    expect_invalid "a CrowdSec image without a digest" "CROWDSEC_IMAGE must be docker.io/crowdsecurity/crowdsec" \
        CROWDSEC_IMAGE=docker.io/crowdsecurity/crowdsec:v1.8.2
    expect_invalid "a plugin hash that is not hex" "CROWDSEC_BOUNCER_PLUGIN_HASH must be 64 lowercase hex digits" \
        CROWDSEC_BOUNCER_PLUGIN_HASH=not-a-hash
    expect_invalid "a bouncer key stored in .env" "Bouncer keys are not stored" \
        BOUNCER_KEY=abcdefghijklmnopqrst
    expect_invalid "an invalid log size" "LOG_MAX_SIZE" LOG_MAX_SIZE=lots

    local -A leak=()
    fixture_valid_env leak
    leak[PG_API_PASSWORD]="fixture-leak-check-value"
    env_validate leak || true
    if printf '%s\n' "${ENV_ERRORS[@]}" "${ENV_WARNINGS[@]}" | grep -qF "fixture-leak-check-value"; then
        t_fail "validation messages never contain secret values"
    else
        t_pass "validation messages never contain secret values"
    fi
    t_check "a placeholder TRAEFIK_ACME_EMAIL is accepted in local TLS mode" expect_valid_quiet

    print_section "Image references"
    local digest
    digest="sha256:$(printf '%064d' 0)"
    t_check "accepts registry/repo:tag@digest" env_image_ref_ok "docker.io/library/traefik:v3.7.17@${digest}"
    local ref
    for ref in "docker.io/library/traefik:latest@${digest}" "docker.io/library/traefik:v3.7.17" \
        "docker.io/library/traefik@${digest}" "docker.io/library/traefik:v3.7.17@sha256:abc" "traefik:v3.7.17@${digest}"; do
        if env_image_ref_ok "${ref}"; then
            t_fail "image reference accepted: ${ref}"
        else
            t_pass "image reference rejected: ${ref:0:48}"
        fi
    done
}

expect_valid_quiet() {
    local -A cfg=()
    fixture_valid_env cfg
    [[ "${cfg[TRAEFIK_ACME_EMAIL]}" == set_* && "${cfg[TRAEFIK_TLS_MODE]}" == local ]] || return 1
    env_validate cfg
}

sync_secret_values() {
    local file="$1" key
    local -A values=()
    env_parse_file "${file}" values
    for key in "${!values[@]}"; do
        [[ "${ENV_POLICY[${key}]:-}" == generated ]] && printf '%s\n' "${values[${key}]}"
    done
    return 0
}

file_state() { stat -c '%i %Y %a %s' "$1"; }

test_env_sync() {
    print_section "Synchronization of .env"
    local dir="${T_RUN_DIR}/sync" target out secrets
    mkdir -m 700 "${dir}"
    target="${dir}/.env"

    t_run env_sync_file "${ENV_EXAMPLE_FILE}" "${target}"
    out="${T_OUT}"
    t_check "creates .env from the example" test "${T_RC}" -eq 0 -a -f "${target}"
    t_check "new .env has mode 600" test "$(file_mode "${target}")" = 600
    t_check "creating .env leaves no temporary file" test -z "$(find "${dir}" -name '.env.tmp.*' -print)"
    mapfile -t secrets < <(sync_secret_values "${target}")
    local count=0 s
    for s in "${secrets[@]}"; do
        [[ "${s}" != set_* && ${#s} -ge 32 ]] && count=$((count + 1))
    done
    t_check "all generated secrets are created (${count}/${#secrets[@]})" test "${count}" -eq "${#secrets[@]}" -a "${count}" -gt 0
    t_check "generated secrets are all different" test "$(printf '%s\n' "${secrets[@]}" | sort -u | wc -l)" -eq "${#secrets[@]}"
    t_check "creating .env prints no secret value" t_no_secret_in "${out}" "${secrets[@]}"
    t_check "user placeholders stay placeholders" grep -qx 'MQTT_HOSTNAME=set_mqtt_hostname' "${target}"

    local before after
    before="$(file_state "${target}")"
    sleep 1
    t_run env_sync_file "${ENV_EXAMPLE_FILE}" "${target}"
    after="$(file_state "${target}")"
    t_check "second run reports unchanged" t_contains "${T_OUT}" "already up to date"
    t_check "second run does not rewrite .env (inode and mtime kept)" test "${before}" = "${after}"
    t_check "second run creates no backup" test -z "$(find "${dir}" -name '.env.bak-*' -print)"

    local old_secret
    old_secret="$(grep '^PG_API_PASSWORD=' "${target}")"
    sed -i 's/^MQTT_HOSTNAME=.*/MQTT_HOSTNAME=sjv-mqtt.serveftp.org/; s/^COMPOSE_PROJECT_NAME=.*/COMPOSE_PROJECT_NAME=tampered/' "${target}"
    local tampered_sum
    tampered_sum="$(sha256sum < "${target}")"
    t_run env_sync_file "${ENV_EXAMPLE_FILE}" "${target}"
    t_check "keeps a user value" grep -qx 'MQTT_HOSTNAME=sjv-mqtt.serveftp.org' "${target}"
    t_check "keeps an existing generated secret" grep -qxF "${old_secret}" "${target}"
    t_check "restores a framework value" grep -qx 'COMPOSE_PROJECT_NAME=infrastructure-sjv' "${target}"
    local backup
    backup="$(find "${dir}" -name '.env.bak-*' -print | head -n 1)"
    t_check "a changed .env is backed up first" test -n "${backup}"
    t_check "the backup holds the previous content" test "$(sha256sum < "${backup}")" = "${tampered_sum}"
    t_check "the backup has mode 600" test "$(file_mode "${backup}")" = 600
    t_check "an update leaves no temporary file" test -z "$(find "${dir}" -name '.env.tmp.*' -print)"

    sed -i 's/^PG_WORKER_PASSWORD=.*/PG_WORKER_PASSWORD=set_pg_worker_password/' "${target}"
    t_run env_sync_file "${ENV_EXAMPLE_FILE}" "${target}"
    t_check "replaces a generated placeholder with a secret" bash -c '! grep -q "^PG_WORKER_PASSWORD=set_" "$1"' _ "${target}"

    printf '%s\n' 'LOCAL_EXTRA=keep-me' >> "${target}"
    t_run env_sync_file "${ENV_EXAMPLE_FILE}" "${target}"
    t_check "keeps an unknown variable and warns" bash -c 'grep -qx "LOCAL_EXTRA=keep-me" "$1" && [[ "$2" == *LOCAL_EXTRA* ]]' _ "${target}" "${T_OUT}"
    before="$(file_state "${target}")"
    t_run env_sync_file "${ENV_EXAMPLE_FILE}" "${target}"
    t_check "a retained variable does not cause rewrites" test "${before}" = "$(file_state "${target}")"

    chmod 644 "${target}"
    t_run env_sync_file "${ENV_EXAMPLE_FILE}" "${target}"
    t_check "tightens an open .env to 600 without rewriting it" test "$(file_mode "${target}")" = 600
    chmod 644 "${backup}"
    t_run env_sync_file "${ENV_EXAMPLE_FILE}" "${target}"
    t_check "tightens an open backup to 600" test "$(file_mode "${backup}")" = 600

    local backups_before sum_before
    printf '%s\n' 'PG_DB=duplicate' >> "${target}"
    sum_before="$(sha256sum < "${target}")"
    backups_before="$(find "${dir}" -name '.env.bak-*' | wc -l)"
    t_expect_fail "refuses to rewrite an unparsable .env" "duplicate variable PG_DB" env_sync_file "${ENV_EXAMPLE_FILE}" "${target}"
    t_check "an unparsable .env is left unchanged" test "$(sha256sum < "${target}")" = "${sum_before}"
    t_check "no backup or temporary file after a refused update" \
        test "$(find "${dir}" -name '.env.bak-*' | wc -l)" -eq "${backups_before}" -a -z "$(find "${dir}" -name '.env.tmp.*' -print)"

    local real="${dir}/real.env" link="${dir}/link-target"
    write_env_file "${real}" 'TZ=Europe/Prague'
    mkdir -m 700 "${link}"
    ln -s "${real}" "${link}/.env"
    t_expect_fail "refuses a symlinked .env" "symlink" env_sync_file "${ENV_EXAMPLE_FILE}" "${link}/.env"
    t_check "the symlink target is untouched" grep -qx 'TZ=Europe/Prague' "${real}"

    local bad_example="${dir}/bad.example"
    cp "${ENV_EXAMPLE_FILE}" "${bad_example}"
    printf '%s\n' 'NOT_IN_POLICY=1' >> "${bad_example}"
    t_expect_fail "rejects an example key without policy" "has no ENV_POLICY entry" env_sync_file "${bad_example}" "${dir}/new.env"
    sed -e '/^NOT_IN_POLICY=/d' -e 's/^PG_API_PASSWORD=.*/PG_API_PASSWORD=real-looking-value/' "${ENV_EXAMPLE_FILE}" > "${bad_example}"
    t_expect_fail "rejects a real value for a generated key in the example" "real value for generated PG_API_PASSWORD" \
        env_sync_file "${bad_example}" "${dir}/new.env"
    t_check "a rejected example creates no .env" test ! -e "${dir}/new.env"

    local open_dir="${dir}/open" group_dir="${dir}/group"
    mkdir -m 777 "${open_dir}"
    t_expect_fail "refuses a world-writable target directory" "writable by the group or by others" \
        env_sync_file "${ENV_EXAMPLE_FILE}" "${open_dir}/.env"
    t_check "a refused world-writable directory is not chmodded" test "$(stat -c '%a' "${open_dir}")" = 777
    t_check "a refused world-writable directory gets no .env" test ! -e "${open_dir}/.env"
    mkdir -m 770 "${group_dir}"
    t_expect_fail "refuses a group-writable target directory" "writable by the group or by others" \
        env_sync_file "${ENV_EXAMPLE_FILE}" "${group_dir}/.env"
    t_check "a refused group-writable directory is not chmodded" test "$(stat -c '%a' "${group_dir}")" = 770
    t_check "a refused group-writable directory gets no .env" test ! -e "${group_dir}/.env"

    local loose="${dir}/loose.env"
    printf '%s\n' 'TOKEN=value' > "${loose}"
    chmod 644 "${loose}"
    ENV_SYNC_TEMP_PATHS=()
    ENV_SYNC_TEMP_INODES=()
    ENV_SYNC_BACKUP_PATH=""
    env_backup_file "${loose}"
    t_check "a backup of a mode 644 file is created as 600" test "$(file_mode "${ENV_SYNC_BACKUP_PATH}")" = 600
    t_check "that backup matches the source" cmp -s "${loose}" "${ENV_SYNC_BACKUP_PATH}"
    t_check "creating the backup leaves the source mode unchanged" test "$(file_mode "${loose}")" = 644
    t_check "creating the backup leaves no temporary file" test -z "$(find "${dir}" -name '.env.tmp.*' -print)"

    local keep="${dir}/.env.tmp.keep" dropme="${dir}/.env.tmp.drop"
    printf '%s\n' 'keep' > "${keep}"
    printf '%s\n' 'drop' > "${dropme}"
    chmod 600 "${keep}" "${dropme}"
    ENV_SYNC_TEMP_PATHS=("${dropme}" "${keep}")
    ENV_SYNC_TEMP_INODES=("$(stat -c '%i' "${dropme}")" "$(stat -c '%i' "${keep}")")
    env_sync_forget_temp "${keep}"
    env_sync_drop_temps
    t_check "cleanup removes only the unfinished temp" test ! -e "${dropme}"
    t_check "cleanup keeps another run's temporary file" test -f "${keep}"
    printf '%s\n' 'drop' > "${dropme}"
    chmod 600 "${dropme}"
    local signal_rc=0
    set +e
    (
        ENV_SYNC_TEMP_PATHS=("${dropme}")
        ENV_SYNC_TEMP_INODES=("$(stat -c '%i' "${dropme}")")
        trap env_sync_drop_temps EXIT
        trap 'env_sync_on_signal INT' INT
        kill -s INT "${BASHPID}"
    )
    signal_rc=$?
    set -e
    t_check "INT removes the unfinished temp" test ! -e "${dropme}"
    t_check "INT keeps another run's temporary file" test -f "${keep}"
    t_check "INT still terminates the writer" test "${signal_rc}" -gt 128
    ENV_SYNC_TEMP_PATHS=()
    ENV_SYNC_TEMP_INODES=()
    rm -f "${keep}"

    if [[ "${EUID}" -ne 0 ]]; then
        t_skip "foreign owner of .env (needs root to create a file owned by another uid)"
    else
        local owned_sum
        chown 1:1 "${target}"
        owned_sum="$(sha256sum < "${target}")"
        t_expect_fail "refuses a .env owned by another uid" "owned by uid" env_sync_file "${ENV_EXAMPLE_FILE}" "${target}"
        t_check "a foreign-owned .env is left unchanged" test "$(sha256sum < "${target}")" = "${owned_sum}"
        t_check "a foreign-owned .env keeps its owner" test "$(stat -c '%u' "${target}")" = 1
        chown "${EUID}:${EUID}" "${target}"
    fi
}

run_env_lib_tests() {
    print_header "Environment library"
    test_env_parse
    test_env_net
    test_env_validate
    test_env_sync
}
