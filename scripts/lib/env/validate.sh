#!/usr/bin/env bash
# Validation of a parsed runtime environment. All problems are collected in
# ENV_ERRORS so one run reports everything; ENV_WARNINGS holds non-fatal notes.

declare -ga ENV_ERRORS=()
declare -ga ENV_WARNINGS=()

env_err() { ENV_ERRORS+=("$*"); }
env_warn() { ENV_WARNINGS+=("$*"); }

readonly ENV_EMAIL_RE='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
readonly ENV_HOSTNAME_RE='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$'
readonly ENV_PG_NAME_RE='^[a-z_][a-z0-9_]{0,62}$'
readonly ENV_MQTT_USER_RE='^[a-z][a-z0-9-]{2,31}$'
readonly ENV_GENERATED_SECRET_RE='^[A-Za-z0-9_-]+$'
readonly ENV_IMAGE_REF_RE='^[a-z0-9.-]+(:[0-9]+)?(/[a-z0-9._-]+)+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$'

env_int_in_range() {
    local value="$1" min="$2" max="$3"
    [[ "${value}" =~ ^[0-9]{1,9}$ ]] || return 1
    (( 10#${value} >= min && 10#${value} <= max ))
}

# Pinned image reference: registry/repository:tag@sha256:digest, never latest.
# Used by the Compose stages; kept here so the rule is tested from the start.
env_image_ref_ok() {
    local ref="$1" tag
    [[ "${ref}" =~ ${ENV_IMAGE_REF_RE} ]] || return 1
    tag="${ref%@*}"
    tag="${tag##*:}"
    [[ "${tag}" != "latest" ]]
}

env_check_subnet_pair() {
    local name="$1" subnet="$2" gateway="$3" prefix
    if ! env_cidr_ok "${subnet}"; then
        env_err "${name}_SUBNET is not an IPv4 CIDR: ${subnet}"
        return
    fi
    prefix="${subnet#*/}"
    env_cidr_is_network_address "${subnet}" || env_err "${name}_SUBNET must be the network address, not ${subnet}."
    (( prefix >= 16 && prefix <= 28 )) || env_err "${name}_SUBNET prefix must be between /16 and /28."
    env_ip_private "${subnet%/*}" || env_err "${name}_SUBNET must be an RFC 1918 or RFC 6598 range."
    if ! env_ipv4_ok "${gateway}"; then
        env_err "${name}_GATEWAY is not an IPv4 address: ${gateway}"
        return
    fi
    if ! env_cidr_contains_ip "${subnet}" "${gateway}"; then
        env_err "${name}_GATEWAY ${gateway} is outside ${name}_SUBNET."
        return
    fi
    local gw_int net_int
    gw_int="$(env_ipv4_to_int "${gateway}")"
    net_int="$(env_ipv4_to_int "${subnet%/*}")"
    (( gw_int != net_int )) || env_err "${name}_GATEWAY must not be the network address."
    (( gw_int != $(env_cidr_broadcast_int "${subnet}") )) || env_err "${name}_GATEWAY must not be the broadcast address."
}

env_check_networks() {
    local -n env_net_ref="$1"
    local names=(DOCKER_PROXY DOCKER_INTERNAL DOCKER_MQTT DOCKER_EGRESS)
    local name other reserved i j
    local -a valid=()
    for name in "${names[@]}"; do
        env_check_subnet_pair "${name}" "${env_net_ref[${name}_SUBNET]}" "${env_net_ref[${name}_GATEWAY]}"
        env_cidr_ok "${env_net_ref[${name}_SUBNET]}" && valid+=("${name}")
    done
    for ((i = 0; i < ${#valid[@]}; i++)); do
        name="${valid[i]}"
        for ((j = i + 1; j < ${#valid[@]}; j++)); do
            other="${valid[j]}"
            if env_cidr_overlaps "${env_net_ref[${name}_SUBNET]}" "${env_net_ref[${other}_SUBNET]}"; then
                env_err "${name}_SUBNET and ${other}_SUBNET overlap."
            fi
        done
        for reserved in "${RESERVED_SUBNETS[@]}"; do
            if env_cidr_overlaps "${env_net_ref[${name}_SUBNET]}" "${reserved}"; then
                env_err "${name}_SUBNET overlaps ${reserved}, which is already used on the host."
            fi
        done
    done
}

# Splits TEXT on spaces into the named array. Does not expand pathnames,
# so a value of "*" stays "*" regardless of the working directory.
env_words() {
    local -n env_words_target="$1"
    local text="$2"
    local IFS=' '
    env_words_target=()
    [[ -n "${text}" ]] || return 0
    # shellcheck disable=SC2034 # nameref: the caller's array is the one that gets filled
    read -r -a env_words_target <<< "${text}"
}

# Space-separated private CIDRs. Prints one reason and returns 1.
env_allowlist_check() {
    local name="$1" list="$2" item count=0
    local -a items=()
    if [[ -z "${list// /}" ]]; then
        printf '%s\n' "${name} is empty."
        return 1
    fi
    if [[ "${list}" == *,* ]]; then
        printf '%s\n' "${name} must be space-separated, not comma-separated."
        return 1
    fi
    env_words items "${list}"
    for item in "${items[@]}"; do
        count=$((count + 1))
        if ! env_cidr_ok "${item}"; then
            printf '%s\n' "${name} contains an invalid CIDR: ${item}"
            return 1
        fi
        if [[ "${item#*/}" == 0 ]]; then
            printf '%s\n' "${name} must not allow every address."
            return 1
        fi
        if ! env_ip_private "${item%/*}" || (( ${item#*/} < 8 )); then
            printf '%s\n' "${name} must contain only private ranges: ${item}"
            return 1
        fi
    done
    (( count > 0 ))
}

env_check_proxy_and_tls() {
    local -n env_tls_ref="$1"
    local mode="${env_tls_ref[PROXY_PROTOCOL_MODE]}" tls="${env_tls_ref[TRAEFIK_TLS_MODE]}"
    local trusted="${env_tls_ref[PROXY_PROTOCOL_TRUSTED_IPS]}" email="${env_tls_ref[TRAEFIK_ACME_EMAIL]}"
    local item

    case "${tls}" in
        local) ;;
        letsencrypt)
            if env_is_placeholder "${email}"; then
                env_err "TRAEFIK_ACME_EMAIL is still a placeholder but TRAEFIK_TLS_MODE=letsencrypt."
            elif [[ ! "${email}" =~ ${ENV_EMAIL_RE} ]]; then
                env_err "TRAEFIK_ACME_EMAIL is not an email address."
            fi
            ;;
        *) env_err "TRAEFIK_TLS_MODE must be local or letsencrypt." ;;
    esac

    case "${mode}" in
        local)
            [[ -z "${trusted}" ]] || env_err "PROXY_PROTOCOL_MODE=local requires an empty PROXY_PROTOCOL_TRUSTED_IPS."
            ;;
        haproxy)
            [[ "${tls}" == letsencrypt ]] || env_err "PROXY_PROTOCOL_MODE=haproxy requires TRAEFIK_TLS_MODE=letsencrypt."
            if [[ -z "${trusted}" ]]; then
                env_err "PROXY_PROTOCOL_MODE=haproxy requires PROXY_PROTOCOL_TRUSTED_IPS."
            else
                local -a trusted_items=()
                env_words trusted_items "${trusted}"
                for item in "${trusted_items[@]}"; do
                    if ! env_cidr_ok "${item}" || [[ "${item}" != */32 ]]; then
                        env_err "PROXY_PROTOCOL_TRUSTED_IPS must list single /32 addresses: ${item}"
                    elif ! env_ip_private "${item%/*}"; then
                        env_err "PROXY_PROTOCOL_TRUSTED_IPS must be a private HAProxy address: ${item}"
                    fi
                done
            fi
            ;;
        *) env_err "PROXY_PROTOCOL_MODE must be local or haproxy." ;;
    esac

    local publish="${env_tls_ref[TRAEFIK_ADMIN_PUBLISH]}"
    if [[ -n "${publish}" ]]; then
        if [[ ! "${publish}" =~ ^([0-9.]+):${TRAEFIK_ADMIN_PORT}:${TRAEFIK_ADMIN_PORT}$ ]]; then
            env_err "TRAEFIK_ADMIN_PUBLISH must look like ADDRESS:${TRAEFIK_ADMIN_PORT}:${TRAEFIK_ADMIN_PORT}."
        else
            local admin_ip="${BASH_REMATCH[1]}"
            if ! env_ipv4_ok "${admin_ip}"; then
                env_err "TRAEFIK_ADMIN_PUBLISH has an invalid address."
            elif [[ "${admin_ip}" == 0.0.0.0 ]] || ! env_ip_private "${admin_ip}"; then
                env_err "TRAEFIK_ADMIN_PUBLISH must bind a private address, never 0.0.0.0 or a public one."
            fi
        fi
    fi

    local reason
    if ! reason="$(env_allowlist_check ADMIN_IP_ALLOWLIST "${env_tls_ref[ADMIN_IP_ALLOWLIST]}")"; then
        env_err "${reason}"
    fi

    if [[ "${mode}" == local ]]; then
        env_warn "PROXY_PROTOCOL_MODE=local: Traefik sees the TCP peer, not the internet client."
    fi
    if [[ "${tls}" == local ]]; then
        env_warn "TRAEFIK_TLS_MODE=local: Traefik serves its default certificate."
    fi
}

env_check_secret_generated() {
    local key="$1" value="$2"
    if (( ${#value} < ENV_MIN_GENERATED_LENGTH )); then
        env_err "${key} is shorter than ${ENV_MIN_GENERATED_LENGTH} characters."
    elif [[ ! "${value}" =~ ${ENV_GENERATED_SECRET_RE} ]]; then
        env_err "${key} must use only A-Z, a-z, 0-9, - and _."
    fi
}

env_check_accounts() {
    local -n env_acc_ref="$1"
    local key value
    local -A seen_names=() seen_secrets=()

    [[ "${env_acc_ref[PG_DB]}" =~ ${ENV_PG_NAME_RE} ]] || env_err "PG_DB is not a valid PostgreSQL name."
    for key in PG_BOOTSTRAP_USER PG_OWNER_USER PG_API_USER PG_COLLECTOR_USER PG_WORKER_USER PG_MAINTENANCE_USER PG_READONLY_USER; do
        value="${env_acc_ref[${key}]}"
        if [[ ! "${value}" =~ ${ENV_PG_NAME_RE} ]]; then
            env_err "${key} is not a valid PostgreSQL role name."
        elif [[ "${value}" == postgres || "${value}" == pg_* ]]; then
            env_err "${key} must not use a reserved PostgreSQL role name."
        elif [[ -v "seen_names[pg:${value}]" ]]; then
            env_err "${key} reuses the role name of ${seen_names[pg:${value}]}."
        else
            seen_names["pg:${value}"]="${key}"
        fi
    done
    for key in MQTT_ADMIN_USER MQTT_COLLECTOR_USER MQTT_HEALTHCHECK_USER; do
        value="${env_acc_ref[${key}]}"
        if [[ "${value,,}" == esp-* || "${value,,}" == concentrator-* ]]; then
            env_err "${key} must not look like a device account."
        elif [[ ! "${value}" =~ ${ENV_MQTT_USER_RE} ]]; then
            env_err "${key} is not a valid MQTT user name."
        elif [[ -v "seen_names[mqtt:${value}]" ]]; then
            env_err "${key} reuses the user name of ${seen_names[mqtt:${value}]}."
        else
            seen_names["mqtt:${value}"]="${key}"
        fi
    done

    local -a generated_keys
    mapfile -t generated_keys < <(printf '%s\n' "${!ENV_POLICY[@]}" | sort)
    for key in "${generated_keys[@]}"; do
        [[ "${ENV_POLICY[${key}]}" == generated ]] || continue
        value="${env_acc_ref[${key}]-}"
        if [[ -z "${value}" ]] || env_is_placeholder "${value}"; then
            continue
        fi
        env_check_secret_generated "${key}" "${value}"
        if [[ -v "seen_secrets[${value}]" ]]; then
            env_err "${key} has the same value as ${seen_secrets[${value}]}. Every account needs its own secret."
        else
            seen_secrets["${value}"]="${key}"
        fi
    done
}

env_check_ingest() {
    local -n env_ing_ref="$1"
    local age="${env_ing_ref[INGEST_MAX_MESSAGE_AGE_DAYS]}" keys="${env_ing_ref[INGEST_KEY_RETENTION_DAYS]}"
    env_int_in_range "${keys}" 2 365 || { env_err "INGEST_KEY_RETENTION_DAYS must be a whole number of days."; return; }
    if ! env_int_in_range "${age}" 1 365; then
        env_err "INGEST_MAX_MESSAGE_AGE_DAYS must be a whole number of days."
    elif (( 10#${age} >= 10#${keys} )); then
        env_err "INGEST_MAX_MESSAGE_AGE_DAYS must be shorter than INGEST_KEY_RETENTION_DAYS (${keys}); otherwise a replay could outlive its idempotency key."
    fi
}

env_check_restic() {
    local -n env_res_ref="$1"
    local repo="${env_res_ref[RESTIC_REPOSITORY]}" password="${env_res_ref[RESTIC_REST_PASSWORD]}"
    if [[ -z "${repo}" ]]; then
        [[ -z "${password}" ]] || env_err "RESTIC_REST_PASSWORD is set but RESTIC_REPOSITORY is empty."
        env_warn "RESTIC_REPOSITORY is empty: no remote backup. Real data must not be loaded until remote backup and a restore test pass."
        return
    fi
    if [[ ! "${repo}" =~ ^rest:https://${STACK_NAME}@([^/:@]+):([0-9]{1,5})/${STACK_NAME}/?$ ]]; then
        env_err "RESTIC_REPOSITORY must be rest:https://${STACK_NAME}@HOST:PORT/${STACK_NAME}/ without a password in the URL."
    elif ! env_int_in_range "${BASH_REMATCH[2]}" 1 65535; then
        env_err "RESTIC_REPOSITORY has an invalid port."
    fi
    (( ${#password} >= ENV_MIN_USER_SECRET_LENGTH )) \
        || env_err "RESTIC_REST_PASSWORD must be at least ${ENV_MIN_USER_SECRET_LENGTH} characters."
}

env_check_smtp() {
    local -n env_smtp_ref="$1"
    local host="${env_smtp_ref[SMTP_HOST]}"
    env_int_in_range "${env_smtp_ref[SMTP_PORT]}" 1 65535 || env_err "SMTP_PORT must be a port number."
    case "${env_smtp_ref[SMTP_SECURITY]}" in
        starttls|tls) ;;
        *) env_err "SMTP_SECURITY must be starttls or tls. Unencrypted SMTP is not allowed." ;;
    esac
    if [[ -z "${host}" ]]; then
        if [[ -n "${env_smtp_ref[SMTP_USER]}${env_smtp_ref[SMTP_PASSWORD]}${env_smtp_ref[MAIL_FROM]}" ]]; then
            env_err "SMTP_USER, SMTP_PASSWORD or MAIL_FROM is set but SMTP_HOST is empty."
        fi
        env_warn "SMTP_HOST is empty: notifications stay queued and are not sent."
        return
    fi
    [[ "${host}" =~ ${ENV_HOSTNAME_RE} ]] || env_err "SMTP_HOST is not a host name."
    [[ -n "${env_smtp_ref[SMTP_USER]}" ]] || env_err "SMTP_HOST is set, so SMTP_USER is required."
    [[ -n "${env_smtp_ref[SMTP_PASSWORD]}" ]] || env_err "SMTP_HOST is set, so SMTP_PASSWORD is required."
    [[ "${env_smtp_ref[MAIL_FROM]}" =~ ${ENV_EMAIL_RE} ]] || env_err "MAIL_FROM must be an email address when SMTP_HOST is set."
}

env_check_images() {
    local -n env_image_ref="$1"
    local image plugin
    image="${env_image_ref[TRAEFIK_IMAGE]}"
    if ! env_image_ref_ok "${image}" || [[ "${image}" != docker.io/library/traefik:*@sha256:* ]]; then
        env_err "TRAEFIK_IMAGE must be docker.io/library/traefik:<tag>@sha256:<64 hex digits>."
    fi
    image="${env_image_ref[CROWDSEC_IMAGE]}"
    if ! env_image_ref_ok "${image}" || [[ "${image}" != docker.io/crowdsecurity/crowdsec:*@sha256:* ]]; then
        env_err "CROWDSEC_IMAGE must be docker.io/crowdsecurity/crowdsec:<tag>@sha256:<64 hex digits>."
    fi
    plugin="${env_image_ref[CROWDSEC_BOUNCER_PLUGIN]}"
    [[ "${plugin}" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
        || env_err "CROWDSEC_BOUNCER_PLUGIN must be a vX.Y.Z version."
}

# Usage: env_validate ARRAY_NAME
# Returns 0 when ENV_ERRORS is empty after all checks.
env_validate() {
    local -n env_val_ref="$1"
    local key value reason
    local -a policy_keys present_keys
    ENV_ERRORS=()
    ENV_WARNINGS=()
    mapfile -t policy_keys < <(printf '%s\n' "${!ENV_POLICY[@]}" | sort)
    mapfile -t present_keys < <(printf '%s\n' "${!env_val_ref[@]}" | sort)

    for key in "${policy_keys[@]}"; do
        [[ -v "env_val_ref[${key}]" ]] || env_err "Missing variable: ${key}"
    done
    for key in "${present_keys[@]}"; do
        if [[ "${key}" == *BOUNCER_KEY* ]]; then
            env_err "Bouncer keys are not stored in .env: ${key}"
        fi
        [[ -z "${key}" || -v "ENV_POLICY[${key}]" ]] || env_err "Unknown variable ${key}. Remove it or add it to the policy."
    done
    if (( ${#ENV_ERRORS[@]} > 0 )); then
        return 1
    fi

    for key in "${policy_keys[@]}"; do
        value="${env_val_ref[${key}]}"
        if [[ -z "${value}" ]]; then
            env_is_optional "${key}" || env_err "Empty variable: ${key}"
            continue
        fi
        if env_is_placeholder "${value}" && ! env_is_deferred_placeholder "${key}"; then
            env_err "Placeholder is not usable: ${key}"
            continue
        fi
        if reason="$(env_value_unsafe_reason "${value}")"; then
            env_err "${key} ${reason}."
        fi
        if [[ "${value}" == *:latest || "${value}" == *:latest@* ]]; then
            env_err "${key} uses the latest tag. Pin an exact version."
        fi
    done
    if (( ${#ENV_ERRORS[@]} > 0 )); then
        return 1
    fi

    [[ "${env_val_ref[COMPOSE_PROJECT_NAME]}" == "${STACK_NAME}" ]] || env_err "COMPOSE_PROJECT_NAME must be ${STACK_NAME}."
    [[ "${env_val_ref[DATA_DIR]}" == "${PRODUCTION_DATA_DIR}" ]] || env_err "DATA_DIR must be ${PRODUCTION_DATA_DIR}."
    [[ "${env_val_ref[BACKUP_LOCAL_DIR]}" == "${PRODUCTION_BACKUP_LOCAL_DIR}" ]] || env_err "BACKUP_LOCAL_DIR must be ${PRODUCTION_BACKUP_LOCAL_DIR}."
    [[ "${env_val_ref[SJV_DOMAIN]}" == "${SJV_DOMAIN}" ]] || env_err "SJV_DOMAIN must be ${SJV_DOMAIN}."
    [[ "${env_val_ref[TZ]}" =~ ^(UTC|[A-Z][A-Za-z_]+(/[A-Za-z0-9_+-]+)+)$ ]] || env_err "TZ is not an IANA time zone name."

    local allowed found=0
    for allowed in "${MQTT_HOSTNAME_ALLOWED[@]}"; do
        [[ "${env_val_ref[MQTT_HOSTNAME]}" == "${allowed}" ]] && found=1
    done
    (( found == 1 )) || env_err "MQTT_HOSTNAME must be one of: ${MQTT_HOSTNAME_ALLOWED[*]}."

    env_check_images "$1"
    env_check_networks "$1"
    env_check_proxy_and_tls "$1"
    env_check_accounts "$1"
    env_check_ingest "$1"
    env_check_restic "$1"
    env_check_smtp "$1"

    [[ "${env_val_ref[LOG_MAX_SIZE]}" =~ ^[1-9][0-9]{0,3}[kmg]$ ]] || env_err "LOG_MAX_SIZE must look like 20m."
    env_int_in_range "${env_val_ref[LOG_MAX_FILES]}" 1 100 || env_err "LOG_MAX_FILES must be between 1 and 100."

    (( ${#ENV_ERRORS[@]} == 0 ))
}
