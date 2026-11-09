#!/usr/bin/env bash
# CrowdSec bouncer registration. The API key is created by cscli after the
# container is running and is stored only in the key file, never in .env,
# Git, or a log line. Temporary copies are removed before the function returns.

post_deploy_bouncer_key_path() {
    printf '%s\n' "${BOUNCER_KEY_FILE}"
}

post_deploy_key_format_ok() {
    local key="$1"
    [[ "${#key}" -ge 20 && "${#key}" -le 200 ]] || return 1
    [[ "${key}" =~ ^[A-Za-z0-9+/=_-]+$ ]]
}

post_deploy_key_trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "${value}"
}

post_deploy_key_file_state() {
    local path="$1" raw trimmed
    [[ -f "${path}" && ! -L "${path}" ]] || { printf '%s\n' missing; return 0; }
    raw="$(<"${path}")" || raw=""
    trimmed="$(post_deploy_key_trim "${raw}")"
    if [[ -z "${trimmed}" ]]; then
        printf '%s\n' empty
        return 0
    fi
    if post_deploy_key_format_ok "${trimmed}"; then
        printf '%s\n' valid
    else
        printf '%s\n' invalid
    fi
}

# Restart when Traefik cannot be shown to have started after the key file.
post_deploy_restart_needed() {
    local file_epoch="$1" started_epoch="$2"
    [[ "${file_epoch}" =~ ^[0-9]+$ && "${started_epoch}" =~ ^[0-9]+$ ]] || return 0
    if (( started_epoch > file_epoch )); then
        return 1
    fi
    return 0
}

post_deploy_raw_has_bouncer() {
    local wanted="$1" line name
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line//$'\r'/}"
        [[ -z "${line}" || "${line}" == name,* || "${line}" == Name,* ]] && continue
        name="${line%%,*}"
        [[ "${name}" == "${wanted}" ]] && return 0
    done
    return 1
}

post_deploy_deletable_bouncer() {
    [[ "$1" == "${CROWDSEC_BOUNCER_NAME}" ]]
}

# valid|missing|empty|invalid, yes|no, 200|403|other
post_deploy_crowdsec_action() {
    local key_state="$1" registered="$2" http="${3:-}"
    case "${key_state}" in
        invalid) printf '%s\n' refuse-invalid ;;
        valid)
            case "${http}" in
                200)
                    if [[ "${registered}" == yes ]]; then
                        printf '%s\n' keep
                    else
                        printf '%s\n' register-existing
                    fi
                    ;;
                403)
                    if [[ "${registered}" == yes ]]; then
                        printf '%s\n' repair-existing
                    else
                        printf '%s\n' register-existing
                    fi
                    ;;
                *) printf '%s\n' abort-lapi ;;
            esac
            ;;
        missing|empty)
            if [[ "${registered}" == yes ]]; then
                printf '%s\n' replace-registered
            else
                printf '%s\n' create-new
            fi
            ;;
        *) printf '%s\n' abort-lapi ;;
    esac
}

post_deploy_stage_key() {
    local src="$1" dest="$2" raw trimmed
    [[ -f "${src}" && ! -L "${src}" ]] || return 1
    raw="$(<"${src}")" || return 1
    trimmed="$(post_deploy_key_trim "${raw}")"
    post_deploy_key_format_ok "${trimmed}" || return 1
    printf '%s\n' "${trimmed}" > "${dest}"
    chmod 600 "${dest}"
}

post_deploy_write_bouncer_key() {
    local key="$1" path dir
    post_deploy_key_format_ok "${key}" || return 1
    path="$(post_deploy_bouncer_key_path)"
    [[ "${path}" == "${BOUNCER_KEY_FILE}" ]] || return 1
    dir="${path%/*}"
    (
        set -Eeuo pipefail
        local tmp=""
        # shellcheck disable=SC2329 # invoked by the EXIT trap below
        cleanup() {
            if [[ -n "${tmp}" && -f "${tmp}" && ! -L "${tmp}" ]]; then
                rm -f -- "${tmp}"
            fi
        }
        # shellcheck disable=SC2329 # invoked by the signal traps below
        on_signal() {
            local sig="$1"
            cleanup
            trap - EXIT INT TERM HUP
            kill -s "${sig}" "${BASHPID}"
        }
        trap cleanup EXIT
        trap 'on_signal INT' INT
        trap 'on_signal TERM' TERM
        trap 'on_signal HUP' HUP
        umask 077
        install -d -m 700 "${dir}"
        tmp="$(mktemp "${dir}/.bouncer-key.XXXXXX")"
        printf '%s\n' "${key}" > "${tmp}"
        chmod 600 "${tmp}"
        mv -f -- "${tmp}" "${path}"
        tmp=""
        chmod 600 "${path}"
    )
}

crowdsec_probe_timeout_seconds() {
    local value="${CROWDSEC_LAPI_PROBE_TIMEOUT:-5}"
    if [[ ! "${value}" =~ ^[1-9][0-9]*$ ]]; then
        value=5
    fi
    printf '%s\n' "${value}"
}

crowdsec_container_state() {
    local running
    if ! running="$(docker_container_running "${CROWDSEC_CONTAINER}" 2>/dev/null)"; then
        printf '%s\n' missing
        return 0
    fi
    if [[ "${running}" == true ]]; then
        printf '%s\n' running
    else
        printf '%s\n' stopped
    fi
}

crowdsec_wait_lapi() {
    local attempts="${CROWDSEC_LAPI_ATTEMPTS:-5}" i
    for ((i = 1; i <= attempts; i++)); do
        if docker_exec "${CROWDSEC_CONTAINER}" cscli bouncers list -o raw >/dev/null 2>&1; then
            return 0
        fi
        if (( i < attempts )); then
            sleep "${CROWDSEC_LAPI_DELAY:-1}"
        fi
    done
    return 1
}

deploy_crowdsec_install_collections() {
    print_section "CrowdSec collections"
    local collection inspection
    if ! crowdsec_wait_lapi; then
        fail "CrowdSec LAPI is not ready. Collections were not installed."
    fi
    for collection in crowdsecurity/linux crowdsecurity/traefik; do
        if inspection="$(docker_exec "${CROWDSEC_CONTAINER}" cscli collections inspect "${collection}" --no-metrics)" \
            && grep -Eq '^installed:[[:space:]]*true$' <<< "${inspection}"; then
            ok "Collection already installed: ${collection}"
            continue
        fi
        docker_exec "${CROWDSEC_CONTAINER}" cscli collections install "${collection}" >/dev/null \
            || fail "Unable to install CrowdSec collection ${collection}."
        inspection="$(docker_exec "${CROWDSEC_CONTAINER}" cscli collections inspect "${collection}" --no-metrics)" \
            || fail "Unable to verify CrowdSec collection ${collection}."
        grep -Eq '^installed:[[:space:]]*true$' <<< "${inspection}" \
            || fail "CrowdSec collection ${collection} is not installed after installation."
        ok "Collection installed: ${collection}"
    done
}

crowdsec_bouncer_registered() {
    local raw
    if ! raw="$(docker_exec "${CROWDSEC_CONTAINER}" cscli bouncers list -o raw 2>/dev/null)"; then
        return 2
    fi
    printf '%s\n' "${raw}" | post_deploy_raw_has_bouncer "${CROWDSEC_BOUNCER_NAME}"
}

# HEAD authenticates the key without the GET that would register another bouncer.
crowdsec_probe_once() {
    local keyfile="$1" timeout_seconds code
    timeout_seconds="$(crowdsec_probe_timeout_seconds)"
    code="$(
        set -Eeuo pipefail
        local staged="" out="" status rc=0
        # shellcheck disable=SC2329 # invoked by the EXIT trap below
        cleanup() {
            [[ -n "${staged}" && -f "${staged}" && ! -L "${staged}" ]] && rm -f -- "${staged}"
            [[ -n "${out}" && -f "${out}" && ! -L "${out}" ]] && rm -f -- "${out}"
        }
        # shellcheck disable=SC2329 # invoked by the signal traps below
        on_signal() {
            local sig="$1"
            cleanup
            trap - EXIT INT TERM HUP
            kill -s "${sig}" "${BASHPID}"
        }
        trap cleanup EXIT
        trap 'on_signal INT' INT
        trap 'on_signal TERM' TERM
        trap 'on_signal HUP' HUP
        umask 077
        staged="$(mktemp)"
        out="$(mktemp)"
        chmod 600 "${staged}" "${out}"
        post_deploy_stage_key "${keyfile}" "${staged}"
        set +e
        # shellcheck disable=SC2016 # the container shell expands the single-quoted script
        docker_exec_timeout "${timeout_seconds}" "${CROWDSEC_CONTAINER}" \
            bash -c 'IFS= read -r key || exit 2
[[ -n "${key}" ]] || exit 2
exec 3<>/dev/tcp/crowdsec/8080 || exit 3
printf "HEAD /v1/decisions HTTP/1.0\r\nHost: crowdsec:8080\r\nX-Api-Key: %s\r\nConnection: close\r\n\r\n" "${key}" >&3
IFS= read -r line <&3 || exit 4
printf "%s\n" "${line}"' < "${staged}" > "${out}"
        rc=$?
        set -e
        [[ "${rc}" -eq 0 ]]
        status="$(<"${out}")"
        printf '%s\n' "${status}" | awk 'NR == 1 { print $2 }' | tr -d '\r'
    )" || return 1
    [[ "${code}" =~ ^[0-9]{3}$ ]] || return 1
    printf '%s\n' "${code}"
}

crowdsec_probe_key_file() {
    local keyfile="$1" attempts="${CROWDSEC_LAPI_ATTEMPTS:-5}" i code=""
    for ((i = 1; i <= attempts; i++)); do
        if code="$(crowdsec_probe_once "${keyfile}")"; then
            case "${code}" in
                200|403)
                    printf '%s\n' "${code}"
                    return 0
                    ;;
            esac
        else
            code=""
        fi
        if (( i < attempts )); then
            sleep "${CROWDSEC_LAPI_DELAY:-1}"
        fi
    done
    if [[ "${code}" =~ ^[0-9]{3}$ ]]; then
        printf '%s\n' "${code}"
    fi
    return 1
}

crowdsec_add_key_file() {
    local keyfile="$1" staged
    staged="$(mktemp)"
    chmod 600 "${staged}"
    if ! post_deploy_stage_key "${keyfile}" "${staged}"; then
        rm -f -- "${staged}"
        return 1
    fi
    # shellcheck disable=SC2016 # the container shell expands the single-quoted script
    if ! docker_exec "${CROWDSEC_CONTAINER}" \
        bash -c 'IFS= read -r key || exit 2
[[ -n "${key}" ]] || exit 2
cscli bouncers add "$1" --key "${key}" >/dev/null' \
        bash "${CROWDSEC_BOUNCER_NAME}" < "${staged}"; then
        rm -f -- "${staged}"
        return 1
    fi
    rm -f -- "${staged}"
}

crowdsec_generate_key() {
    local out key
    out="$(mktemp)"
    chmod 600 "${out}"
    if ! docker_exec "${CROWDSEC_CONTAINER}" cscli bouncers add "${CROWDSEC_BOUNCER_NAME}" -o raw > "${out}"; then
        rm -f -- "${out}"
        return 1
    fi
    key="$(tr -d '[:space:]' < "${out}")"
    rm -f -- "${out}"
    post_deploy_key_format_ok "${key}" || return 1
    printf '%s\n' "${key}"
}

crowdsec_delete_bouncer() {
    local name="$1"
    post_deploy_deletable_bouncer "${name}" || return 1
    docker_exec "${CROWDSEC_CONTAINER}" cscli bouncers delete "${name}" >/dev/null
}

post_deploy_restart_traefik_if_needed() {
    local path file_epoch started_raw started_epoch
    path="$(post_deploy_bouncer_key_path)"
    [[ -f "${path}" && ! -L "${path}" ]] || fail "Bouncer key file is missing, so Traefik was not restarted."
    file_epoch="$(stat -c '%Y' "${path}")"
    if ! started_raw="$(docker_container_started "${TRAEFIK_CONTAINER}")"; then
        fail "Traefik start time is unavailable. The next run will retry the restart."
    fi
    if ! started_epoch="$(date -u -d "${started_raw}" +%s)"; then
        fail "Traefik start time could not be read. The next run will retry the restart."
    fi
    if post_deploy_restart_needed "${file_epoch}" "${started_epoch}"; then
        docker_restart "${TRAEFIK_CONTAINER}" \
            || fail "Traefik restart failed. The next run will retry the restart."
        ok "Traefik restarted to load the bouncer key."
    else
        ok "Traefik already started after the bouncer key. It was not restarted."
    fi
}

post_deploy_store_generated_key() {
    local key
    key="$(crowdsec_generate_key)" || return 1
    post_deploy_key_format_ok "${key}" || return 1
    post_deploy_write_bouncer_key "${key}"
}

post_deploy_crowdsec() {
    print_section "CrowdSec bouncer"
    local state path key_state registered list_rc http action
    state="$(crowdsec_container_state)"
    case "${state}" in
        running) ;;
        missing) fail "CrowdSec container ${CROWDSEC_CONTAINER} does not exist. No bouncer was changed." ;;
        *) fail "CrowdSec container ${CROWDSEC_CONTAINER} is not running. No bouncer was changed." ;;
    esac
    if ! crowdsec_wait_lapi; then
        fail "CrowdSec LAPI is not ready. No bouncer was changed."
    fi
    path="$(post_deploy_bouncer_key_path)"
    key_state="$(post_deploy_key_file_state "${path}")"
    [[ "${key_state}" != invalid ]] \
        || fail "Bouncer key file is not empty but its format is not recognized. It was not replaced."
    registered=no
    if crowdsec_bouncer_registered; then
        registered=yes
    else
        list_rc=$?
        [[ "${list_rc}" -ne 2 ]] || fail "CrowdSec LAPI bouncer list failed. No bouncer was changed."
        registered=no
    fi
    http=""
    if [[ "${key_state}" == valid ]]; then
        if ! http="$(crowdsec_probe_key_file "${path}")"; then
            if [[ "${http}" =~ ^[0-9]{3}$ ]]; then
                fail "CrowdSec LAPI returned status ${http}. No bouncer was changed."
            fi
            fail "CrowdSec LAPI did not answer the key check. No bouncer was changed."
        fi
    fi
    action="$(post_deploy_crowdsec_action "${key_state}" "${registered}" "${http}")"
    case "${action}" in
        refuse-invalid)
            fail "Bouncer key file is not empty but its format is not recognized. It was not replaced."
            ;;
        abort-lapi)
            fail "CrowdSec LAPI did not accept a key check. No bouncer was changed."
            ;;
        keep)
            chmod 600 "${path}"
            ok "Bouncer key already matches LAPI and was not replaced."
            ;;
        register-existing)
            crowdsec_add_key_file "${path}" \
                || fail "Unable to register the existing bouncer key. The key file was not replaced."
            chmod 600 "${path}"
            ok "Existing bouncer key registered. The key was not logged."
            ;;
        repair-existing)
            crowdsec_delete_bouncer "${CROWDSEC_BOUNCER_NAME}" \
                || fail "Unable to replace bouncer ${CROWDSEC_BOUNCER_NAME}. Other bouncers were not removed and the key file was not replaced."
            crowdsec_add_key_file "${path}" \
                || fail "Bouncer ${CROWDSEC_BOUNCER_NAME} was removed and the existing key could not be registered again. The key file was not replaced."
            chmod 600 "${path}"
            ok "Bouncer registration now uses the stored key. The key was not logged."
            ;;
        replace-registered)
            crowdsec_delete_bouncer "${CROWDSEC_BOUNCER_NAME}" \
                || fail "Unable to remove bouncer ${CROWDSEC_BOUNCER_NAME}. No new key was written."
            post_deploy_store_generated_key \
                || fail "Unable to create a new bouncer key. No partial key was written."
            ok "New bouncer key stored. The key was not logged."
            ;;
        create-new)
            post_deploy_store_generated_key \
                || fail "Unable to create bouncer ${CROWDSEC_BOUNCER_NAME}. No partial key was written."
            ok "Bouncer key stored. The key was not logged."
            ;;
        *)
            fail "Unknown CrowdSec bouncer action. No bouncer was changed."
            ;;
    esac
    deploy_render_runtime
    post_deploy_restart_traefik_if_needed
}
