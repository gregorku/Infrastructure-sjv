#!/usr/bin/env bash
# Static checks of the repository: syntax, forbidden constructs, secrets
# hygiene and consistency between .env.example and ENV_POLICY.
# shellcheck disable=SC2016,SC2034
# SC2016: detector samples are literal text. SC2034: arrays are passed by name.

# Shell files checked by these tests. This file is excluded from the
# pattern scan because it necessarily contains the forbidden patterns.
static_shell_files() {
    find "${REPO_ROOT}/scripts" "${REPO_ROOT}/postgresql" -type f -name '*.sh' -print | sort
}

# Prints non-comment lines matching an extended regex as file:line: text.
# The regex is passed through the environment because awk -v would
# interpret its backslashes.
static_grep_code() {
    local regex="$1" file
    shift
    for file in "$@"; do
        [[ "${file}" == */lib/tests/test-static.sh ]] && continue
        STATIC_RE="${regex}" awk -v f="${file#"${REPO_ROOT}"/}" '
            /^[[:space:]]*#/ { next }
            $0 ~ ENVIRON["STATIC_RE"] { printf "%s:%d: %s\n", f, NR, $0 }
        ' "${file}"
    done
}

static_test_syntax() {
    print_section "Syntax (bash -n)"
    local file failed=0
    while IFS= read -r file; do
        if ! bash -n "${file}" 2>/dev/null; then
            t_fail "bash -n ${file#"${REPO_ROOT}"/}"
            failed=1
        fi
    done < <(static_shell_files)
    (( failed == 1 )) || t_pass "bash -n: all $(static_shell_files | wc -l) shell files parse"
}

static_test_headers() {
    print_section "Script headers and permissions"
    local file bad=()
    while IFS= read -r file; do
        [[ "$(head -n 1 "${file}")" == '#!/usr/bin/env bash' ]] || bad+=("${file#"${REPO_ROOT}"/}")
    done < <(static_shell_files)
    t_check "every shell file starts with #!/usr/bin/env bash" test "${#bad[@]}" -eq 0
    (( ${#bad[@]} == 0 )) || printf '    %s\n' "${bad[@]}"

    bad=()
    for file in "${REPO_ROOT}"/scripts/*.sh; do
        [[ "${file}" == */config.sh ]] && continue
        head -n 5 "${file}" | grep -qx 'set -Eeuo pipefail' || bad+=("${file##*/}: no set -Eeuo pipefail")
        [[ -x "${file}" ]] || bad+=("${file##*/}: not executable")
        grep -q '^log_install_err_trap$' "${file}" || [[ "${file}" == */test.sh || "${file}" == */shellcheck.sh ]] \
            || bad+=("${file##*/}: no error trap")
    done
    t_check "entry scripts use strict mode, error trap and are executable" test "${#bad[@]}" -eq 0
    (( ${#bad[@]} == 0 )) || printf '    %s\n' "${bad[@]}"
}

static_test_forbidden() {
    print_section "Forbidden constructs"
    local -a files
    mapfile -t files < <(static_shell_files)
    # Command names are matched only in command position, so the same words
    # inside messages and test descriptions do not count.
    local cmd_pos='(^[[:space:]]*|[;&|(][[:space:]]*|\$\([[:space:]]*|then[[:space:]]+|do[[:space:]]+)'
    local -a checks=(
        'eval|(^|[^A-Za-z0-9_])eval([[:space:]]|$)'
        'shell tracing (set -x)|set[[:space:]]+-[A-Za-z]*x|set[[:space:]]+-o[[:space:]]+xtrace'
        'download piped into a shell|(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh'
        'world-writable or recursive chmod|chmod[[:space:]]+(-R|[0-7]{2,3}[2367]([[:space:]]|$)|a\+w|o\+w)'
        "sudo|${cmd_pos}sudo([[:space:]]|\$)"
        "Docker commands outside scripts/lib/deploy/docker.sh|${cmd_pos}docker([[:space:]]|\$)"
        "external infrastructure commands|${cmd_pos}(zfs|zpool|incus|nixos-rebuild|restic|rest-server|wg|wg-quick|nft|iptables|systemctl)([[:space:]]|\$)"
        'secret variable printed|(echo|printf|info|ok|warn|error|fail)[^#]*\$\{?[A-Z_]*(PASSWORD|SECRET|TOKEN)'
        'source of an .env file|(source|\.)[[:space:]]+[^[:space:]]*\.env([[:space:]]|"|$)'
    )
    # One offending sample per check, in the same order; each must be detected.
    local -a samples=(
        'eval "${cmd}"'
        'set -x'
        'curl -fsSL https://example.org/x | sudo bash'
        'chmod 0777 "${dir}"'
        'sudo true'
        'docker compose up -d'
        'if true; then zfs create pool/x; fi'
        'printf "%s\n" "${PG_API_PASSWORD}"'
        'source "${STACK_DIR}/.env"'
    )
    local canary="${T_RUN_DIR}/canary.sh" i
    local entry label regex hits
    for i in "${!checks[@]}"; do
        regex="${checks[${i}]#*|}"
        printf '%s\n' "${samples[${i}]}" > "${canary}"
        if [[ -n "$(static_grep_code "${regex}" "${canary}")" ]]; then
            t_pass "detector works: ${checks[${i}]%%|*}"
        else
            t_fail "detector misses its sample: ${checks[${i}]%%|*}"
        fi
    done
    rm -f "${canary}"

    for entry in "${checks[@]}"; do
        label="${entry%%|*}"
        regex="${entry#*|}"
        hits="$(static_grep_code "${regex}" "${files[@]}")"
        if [[ "${label}" == Docker\ commands* ]]; then
            hits="$(printf '%s\n' "${hits}" | grep -v '^scripts/lib/deploy/docker.sh:' || true)"
        fi
        if [[ -z "${hits}" ]]; then
            t_pass "no ${label}"
        else
            t_fail "found ${label}"
            printf '    %s\n' "${hits}"
        fi
    done

    local line bad_docker=()
    while IFS= read -r line; do
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ "${line}" =~ ^[[:space:]]*(timeout[[:space:]].*[[:space:]])?docker[[:space:]] ]] || continue
        [[ "${line}" =~ ^[[:space:]]*docker[[:space:]]+network[[:space:]]+inspect([[:space:]]|$) ]] && continue
        [[ "${line}" =~ ^[[:space:]]*docker[[:space:]]+network[[:space:]]+ls([[:space:]]|$) ]] && continue
        [[ "${line}" =~ ^[[:space:]]*docker[[:space:]]+network[[:space:]]+create([[:space:]]|$) ]] && continue
        [[ "${line}" =~ ^[[:space:]]*docker[[:space:]]+inspect([[:space:]]|$) ]] && continue
        [[ "${line}" =~ ^[[:space:]]*docker[[:space:]]+exec([[:space:]]|$) ]] && continue
        [[ "${line}" =~ ^[[:space:]]*docker[[:space:]]+restart([[:space:]]|$) ]] && continue
        [[ "${line}" =~ ^[[:space:]]*docker[[:space:]]+compose([[:space:]]|$) ]] && continue
        [[ "${line}" =~ ^[[:space:]]*timeout[[:space:]].*[[:space:]]docker[[:space:]]+exec[[:space:]] ]] && continue
        bad_docker+=("${line}")
    done < "${REPO_ROOT}/scripts/lib/deploy/docker.sh"
    if (( ${#bad_docker[@]} == 0 )); then
        t_pass "docker.sh only uses inspect, create, exec, restart and compose"
    else
        t_fail "docker.sh has an unexpected docker invocation"
        printf '    %s\n' "${bad_docker[@]}"
    fi
    hits="$(static_grep_code 'network[[:space:]]+rm|network[[:space:]]+remove|compose[[:space:]]+down|compose[[:space:]]+rm|--privileged|docker[[:space:]]+system|docker[[:space:]]+volume|docker[[:space:]]+run' "${files[@]}")"
    if [[ -z "${hits}" ]]; then
        t_pass "no Docker socket, volume, prune or container removal"
    else
        t_fail "found a forbidden Docker operation"
        printf '    %s\n' "${hits}"
    fi

    hits="$(static_grep_code 'rm[[:space:]]+-[A-Za-z]*r[A-Za-z]*f|rm[[:space:]]+-[A-Za-z]*f[A-Za-z]*r' "${files[@]}" | grep -v '^scripts/test.sh:' || true)"
    if [[ -z "${hits}" ]]; then
        t_pass "recursive rm only in the guarded test cleanup"
    else
        t_fail "recursive rm outside scripts/test.sh"
        printf '    %s\n' "${hits}"
    fi
}

static_test_repository() {
    print_section "Repository hygiene"
    t_check "no runtime .env in the checkout" test ! -e "${REPO_ROOT}/.env"
    local pattern missing=()
    for pattern in '.env' '.env.bak-*' '.env.tmp.*' '.env.lock' '.test-tmp/' '*.pem' '*.key' 'acme.json' 'app-kek' 'restic-key-password' 'restic-rest-server.crt'; do
        grep -qxF -- "${pattern}" "${REPO_ROOT}/.gitignore" || missing+=("${pattern}")
    done
    t_check ".gitignore covers runtime secrets and test output" test "${#missing[@]}" -eq 0
    (( ${#missing[@]} == 0 )) || printf '    missing: %s\n' "${missing[@]}"

    local found
    found="$(find "${REPO_ROOT}" -path "${REPO_ROOT}/.git" -prune -o -path "${TEST_TMP_ROOT}" -prune -o \
        -type f \( -name '.env' -o -name '.env.bak-*' -o -name '*.pem' -o -name '*.key' -o -name 'acme.json' -o -name 'app-kek' \) -print)"
    t_check "no secret-like files in the checkout" test -z "${found}"
    [[ -z "${found}" ]] || printf '    %s\n' "${found}"

    found="$(find "${REPO_ROOT}/docs" -type f -name '*[A-Z]*' -print)"
    t_check "documentation file names are lowercase" test -z "${found}"
    [[ -z "${found}" ]] || printf '    %s\n' "${found}"

    found="$(grep -nE ':latest([^A-Za-z0-9_]|$)' "${REPO_ROOT}/.env.example" "${REPO_ROOT}/scripts/config.sh" || true)"
    t_check "no latest tag in .env.example or config.sh" test -z "${found}"
    [[ -z "${found}" ]] || printf '    %s\n' "${found}"

    local public_domain="serve"
    public_domain+="ftp.org"
    found="$(grep -RInFi --exclude-dir=.git --exclude-dir=.test-tmp -- "${public_domain}" "${REPO_ROOT}" || true)"
    t_check "the checkout contains no real public domain" test -z "${found}"
    [[ -z "${found}" ]] || printf '    %s\n' "${found}"
}

static_test_env_example() {
    print_section ".env.example and ENV_POLICY"
    t_expect_ok ".env.example parses without unsafe values" env_parse_file "${ENV_EXAMPLE_FILE}" STATIC_EXAMPLE
    t_expect_ok ".env.example and ENV_POLICY list the same keys" env_check_example_policy "${ENV_EXAMPLE_FILE}"

    local -A example=()
    env_parse_file "${ENV_EXAMPLE_FILE}" example
    local key bad=()
    for key in "${!example[@]}"; do
        if env_is_sensitive "${key}" && [[ -n "${example[${key}]}" ]] && ! env_is_placeholder "${example[${key}]}"; then
            bad+=("${key}")
        fi
    done
    t_check ".env.example contains no secret values" test "${#bad[@]}" -eq 0
    (( ${#bad[@]} == 0 )) || printf '    %s\n' "${bad[@]}"

    t_check "SJV_DOMAIN is user-managed" test "${ENV_POLICY[SJV_DOMAIN]}" = user
    t_check "MQTT_HOSTNAME is user-managed" test "${ENV_POLICY[MQTT_HOSTNAME]}" = user
    t_check "SJV_DOMAIN in .env.example is the documentation hostname" test "${example[SJV_DOMAIN]}" = example.com
    t_check "MQTT_HOSTNAME in .env.example is the documentation hostname" test "${example[MQTT_HOSTNAME]}" = mqtt.example.com
    t_check "example.com is a documentation hostname" env_is_documentation_hostname example.com
    t_check "mqtt.example.com is a documentation hostname" env_is_documentation_hostname mqtt.example.com
    local reserved="10.10.10.0/24 10.100.101.0/24 10.110.110.0/24 10.120.120.0/24 172.17.0.0/16"
    t_check "reserved subnets are the current VPS ranges" test "${RESERVED_SUBNETS[*]}" = "${reserved}"
    t_check "the example proxy subnet is 172.20.0.0/24" test "${example[DOCKER_PROXY_SUBNET]}" = "172.20.0.0/24" -a "${example[DOCKER_PROXY_GATEWAY]}" = "172.20.0.1"
    t_check "the example internal subnet is 172.21.0.0/24" test "${example[DOCKER_INTERNAL_SUBNET]}" = "172.21.0.0/24" -a "${example[DOCKER_INTERNAL_GATEWAY]}" = "172.21.0.1"
    t_check "the example mqtt subnet is 172.22.0.0/24" test "${example[DOCKER_MQTT_SUBNET]}" = "172.22.0.0/24" -a "${example[DOCKER_MQTT_GATEWAY]}" = "172.22.0.1"
    t_check "the example egress subnet is 172.23.0.0/24" test "${example[DOCKER_EGRESS_SUBNET]}" = "172.23.0.0/24" -a "${example[DOCKER_EGRESS_GATEWAY]}" = "172.23.0.1"

    local -A sample=()
    env_parse_file "${ENV_EXAMPLE_FILE}" sample
    if env_validate sample; then
        t_fail ".env.example as-is is rejected by the validator"
    else
        t_pass ".env.example as-is is rejected by the validator"
    fi

    local key
    for key in "${!ENV_POLICY[@]}"; do
        if [[ "${ENV_POLICY[${key}]}" == generated ]]; then
            sample[${key}]="$(env_generate_secret)"
        fi
    done
    sample[TRAEFIK_ACME_EMAIL]="admin@example.net"
    if env_validate sample; then
        t_fail "documentation hostnames are rejected when the rest of .env.example is complete"
    else
        local joined
        joined="$(printf '%s\n' "${ENV_ERRORS[@]}")"
        if [[ "${joined}" == *"SJV_DOMAIN is a documentation placeholder (example.com)"* \
            && "${joined}" == *"MQTT_HOSTNAME is a documentation placeholder (mqtt.example.com)"* ]]; then
            t_pass "documentation hostnames are rejected when the rest of .env.example is complete"
        else
            t_fail "documentation hostnames are rejected when the rest of .env.example is complete"
            printf '    %s\n' "${joined}"
        fi
    fi
}

declare -gA STATIC_EXAMPLE=()

run_static_tests() {
    print_header "Static checks"
    static_test_syntax
    static_test_headers
    static_test_forbidden
    static_test_repository
    static_test_env_example
}
