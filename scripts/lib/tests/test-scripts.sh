#!/usr/bin/env bash
# End-to-end tests of init.sh, update-env.sh and check-env.sh. The scripts
# run as child processes in test mode against a base directory inside
# .test-tmp; /docker-data is never used.
# shellcheck disable=SC2016
# Child scripts below are single-quoted so this process does not expand them.

T_BASE=""

run_script() {
    local script="$1"
    shift
    t_run env NO_COLOR=1 SJV_TEST_BASE_DIR="${T_BASE}" "${REPO_ROOT}/scripts/${script}" "$@"
}

# True when the guard rejects the path. Runs in this shell, where the
# function from config.sh is defined.
refuse_test_base() {
    ! sjv_test_base_acceptable "$1" "$2"
}

# Snapshot of names, modes, inodes, sizes and mtimes under the base.
tree_state() {
    find "${T_BASE}" -printf '%P %m %i %s %T@\n' | sort
}

runtime_secrets() {
    sync_secret_values "${T_BASE}/stacks/infrastructure-sjv/.env"
}

# Rewrites one value in place, keeping the inode and mode of the file.
set_env_value() {
    local file="$1" key="$2" value="$3" tmp
    tmp="$(mktemp "${T_RUN_DIR}/set.XXXXXX")"
    awk -v k="${key}" -v v="${value}" 'BEGIN { FS = OFS = "=" }
        $1 == k { print k "=" v; next } { print }' "${file}" > "${tmp}"
    cat "${tmp}" > "${file}"
    rm -f "${tmp}"
}

fill_fixture_values() {
    local file="$1" key
    local -A cfg=()
    fixture_valid_env cfg
    for key in MQTT_HOSTNAME ADMIN_IP_ALLOWLIST \
        DOCKER_PROXY_SUBNET DOCKER_PROXY_GATEWAY DOCKER_INTERNAL_SUBNET DOCKER_INTERNAL_GATEWAY \
        DOCKER_MQTT_SUBNET DOCKER_MQTT_GATEWAY DOCKER_EGRESS_SUBNET DOCKER_EGRESS_GATEWAY; do
        set_env_value "${file}" "${key}" "${cfg[${key}]}"
    done
}

test_scripts_guard() {
    print_section "Test-mode guard"
    t_check "the prepared .test-tmp base is accepted" sjv_test_base_acceptable "${T_BASE}" "${TEST_TMP_ROOT}"

    t_run env NO_COLOR=1 SJV_TEST_BASE_DIR=/tmp/sjv-elsewhere "${REPO_ROOT}/scripts/init.sh"
    t_check "SJV_TEST_BASE_DIR outside .test-tmp is refused" \
        bash -c '(( $1 != 0 )) && [[ "$2" == *"must be an existing test directory"* ]]' _ "${T_RC}" "${T_OUT}"
    t_check "the refused path was not created" test ! -e /tmp/sjv-elsewhere
    t_check "a path outside the checkout is refused" \
        refuse_test_base "/tmp/sjv-not-created/name/base" "${TEST_TMP_ROOT}"
    t_check "the outside path was not created" test ! -e /tmp/sjv-not-created

    t_run env NO_COLOR=1 SJV_TEST_BASE_DIR="${REPO_ROOT}/atest-tmp/name/base" "${REPO_ROOT}/scripts/init.sh"
    t_check "atest-tmp is refused" test "${T_RC}" -ne 0
    t_check "atest-tmp was not created" test ! -e "${REPO_ROOT}/atest-tmp"
    t_run env NO_COLOR=1 SJV_TEST_BASE_DIR="${REPO_ROOT}//test-tmp/name/base" "${REPO_ROOT}/scripts/init.sh"
    t_check "//test-tmp is refused" test "${T_RC}" -ne 0
    t_check "a lookalike test-tmp directory was not created" test ! -e "${REPO_ROOT}/test-tmp"

    t_run env NO_COLOR=1 SJV_TEST_BASE_DIR="${T_RUN_DIR}" "${REPO_ROOT}/scripts/init.sh"
    t_check "a test base not ending in /base is refused" test "${T_RC}" -ne 0

    local guard="${T_RUN_DIR}/guard" linked
    mkdir -p "${guard}/target/name/base" "${guard}/checkout"
    ln -s "${guard}/target" "${guard}/checkout/.test-tmp"
    linked="${guard}/checkout/.test-tmp/name/base"
    t_check "a symlinked .test-tmp is refused" \
        refuse_test_base "${linked}" "${guard}/checkout/.test-tmp"
    t_check "the symlink target was not used as a base" test -d "${guard}/target/name/base"

    mkdir -p "${guard}/inner/.test-tmp/real/base"
    ln -s real "${guard}/inner/.test-tmp/alias"
    t_check "a symlink inside .test-tmp is refused" \
        refuse_test_base "${guard}/inner/.test-tmp/alias/base" "${guard}/inner/.test-tmp"
    mkdir -p "${guard}/inner/.test-tmp/name"
    ln -s "${guard}/inner/.test-tmp/name" "${guard}/inner/.test-tmp/name/base"
    t_check "a symlinked base directory is refused" \
        refuse_test_base "${guard}/inner/.test-tmp/name/base" "${guard}/inner/.test-tmp"

    run_script init.sh --bogus
    t_check "an unknown option is refused" bash -c '(( $1 != 0 )) && [[ "$2" == *"Unknown option"* ]]' _ "${T_RC}" "${T_OUT}"

    local script
    for script in init.sh update-env.sh check-env.sh deploy.sh post-deploy.sh reload.sh create-dashboard-user.sh; do
        t_run env -u SJV_TEST_BASE_DIR NO_COLOR=1 "${REPO_ROOT}/scripts/${script}"
        t_check "${script} without root is refused" \
            bash -c '(( $1 != 0 )) && [[ "$2" == *"must be run as root"* ]]' _ "${T_RC}" "${T_OUT}"
    done
    t_check "a refused non-root run creates no /docker-data" test ! -e /docker-data

    if command -v unshare >/dev/null 2>&1; then
        for script in update-env.sh check-env.sh init.sh deploy.sh post-deploy.sh reload.sh create-dashboard-user.sh; do
            t_run unshare --map-auto --map-root-user env -u SJV_TEST_BASE_DIR NO_COLOR=1 "${REPO_ROOT}/scripts/${script}"
            t_check "${script} refuses a missing /docker-data mount" \
                bash -c '(( $1 != 0 )) && [[ "$2" == *"/docker-data does not exist"* ]]' _ "${T_RC}" "${T_OUT}"
        done
        t_check "a refused mount check creates no /docker-data" test ! -e /docker-data
    else
        t_skip "missing /docker-data mount (unshare is not available)"
    fi
}

test_scripts_init() {
    print_section "init.sh"
    local stack="${T_BASE}/stacks/infrastructure-sjv" data="${T_BASE}/infrastructure-sjv"

    run_script update-env.sh
    t_check "update-env.sh before init.sh fails clearly" \
        bash -c '(( $1 != 0 )) && [[ "$2" == *"Run ./scripts/init.sh first"* ]]' _ "${T_RC}" "${T_OUT}"

    run_script init.sh
    t_check "init.sh succeeds" test "${T_RC}" -eq 0
    t_check "stack directory exists (750)" test "$(stat -c %a "${stack}")" = 750
    t_check "state directory is private (700)" test "$(stat -c %a "${data}/state")" = 700
    t_check "secrets directory is private (700)" test "$(stat -c %a "${data}/secrets")" = 700
    t_check "backup directory is private (700)" test "$(stat -c %a "${T_BASE}/backups/infrastructure-sjv")" = 700
    t_check ".env.example is copied unchanged" cmp -s "${ENV_EXAMPLE_FILE}" "${stack}/.env.example"
    t_check "init.sh does not create .env" test ! -e "${stack}/.env"

    local before
    before="$(tree_state)"
    sleep 1
    run_script init.sh
    t_check "second init.sh succeeds" test "${T_RC}" -eq 0
    t_check "second init.sh changes nothing" test "${before}" = "$(tree_state)"
    t_check "second init.sh reports unchanged files" t_contains "${T_OUT}" "Unchanged .env.example"

    chmod 755 "${data}/state"
    run_script init.sh
    t_check "init.sh tightens an open state directory to 700" \
        bash -c '[[ "$(stat -c %a "$1")" == 700 && "$2" == *"Tightened to 700"* ]]' _ "${data}/state" "${T_OUT}"

    mv "${data}/secrets" "${data}/secrets.real"
    ln -s "${data}/secrets.real" "${data}/secrets"
    run_script init.sh
    t_check "init.sh refuses a symlinked secrets directory" \
        bash -c '(( $1 != 0 )) && [[ "$2" == *"is a symlink"* ]]' _ "${T_RC}" "${T_OUT}"
    rm -f "${data}/secrets"
    mv "${data}/secrets.real" "${data}/secrets"
}

test_scripts_env() {
    print_section "update-env.sh and check-env.sh"
    local stack="${T_BASE}/stacks/infrastructure-sjv" env_file before secrets
    env_file="${stack}/.env"

    run_script update-env.sh
    t_check "update-env.sh creates .env" bash -c '(( $1 == 0 )) && [[ -f "$2" ]]' _ "${T_RC}" "${env_file}"
    t_check "runtime .env has mode 600" test "$(stat -c %a "${env_file}")" = 600
    mapfile -t secrets < <(runtime_secrets)
    t_check "update-env.sh prints no secret value" t_no_secret_in "${T_OUT}" "${secrets[@]}"
    t_check "update-env.sh lists remaining placeholders by name" t_contains "${T_OUT}" "MQTT_HOSTNAME"

    before="$(tree_state)"
    sleep 1
    run_script update-env.sh
    t_check "second update-env.sh leaves .env untouched" \
        bash -c '(( $1 == 0 )) && [[ "$2" == *"already up to date"* ]]' _ "${T_RC}" "${T_OUT}"
    t_check "second update-env.sh creates no backup" test -z "$(find "${stack}" -name '.env.bak-*' -print)"
    t_check "second update-env.sh changes no file" test "${before}" = "$(tree_state)"

    before="$(tree_state)"
    run_script check-env.sh
    t_check "check-env.sh rejects placeholders" \
        bash -c '(( $1 != 0 )) && [[ "$2" == *"Placeholder is not usable: MQTT_HOSTNAME"* ]]' _ "${T_RC}" "${T_OUT}"
    t_check "check-env.sh reports every problem at once" t_contains "${T_OUT}" "Placeholder is not usable: DOCKER_EGRESS_SUBNET"
    t_check "check-env.sh prints no secret value" t_no_secret_in "${T_OUT}" "${secrets[@]}"
    t_check "a failing check-env.sh changes nothing" test "${before}" = "$(tree_state)"

    fill_fixture_values "${env_file}"
    before="$(tree_state)"
    run_script check-env.sh
    t_check "check-env.sh accepts a complete configuration" test "${T_RC}" -eq 0
    [[ "${T_RC}" -eq 0 ]] || printf '%s\n' "${T_OUT}" | tail -n 15
    t_check "check-env.sh warns that remote backup is not configured" t_contains "${T_OUT}" "RESTIC_REPOSITORY is empty"
    t_check "a passing check-env.sh changes nothing" test "${before}" = "$(tree_state)"
    t_check "a passing check-env.sh prints no secret value" t_no_secret_in "${T_OUT}" "${secrets[@]}"

    local orphan="${stack}/.env.tmp.orphan" other="${stack}/.env.tmp.other"
    printf '%s\n' 'orphan' > "${orphan}"
    printf '%s\n' 'other' > "${other}"
    chmod 600 "${orphan}" "${other}"
    before="$(sha256sum < "${env_file}")"
    run_script check-env.sh
    t_check "check-env.sh rejects an orphan temporary file" \
        bash -c '(( $1 != 0 )) && [[ "$2" == *"interrupted update"* ]]' _ "${T_RC}" "${T_OUT}"
    t_check "check-env.sh does not delete orphan temporary files" test -f "${orphan}" -a -f "${other}"
    t_check "an orphan temporary file does not change .env" test "$(sha256sum < "${env_file}")" = "${before}"
    rm -f "${orphan}" "${other}"

    before="$(sha256sum < "${env_file}")"
    run_script update-env.sh
    t_check "update-env.sh keeps filled-in user values" test "$(sha256sum < "${env_file}")" = "${before}"

    chmod 644 "${env_file}"
    run_script check-env.sh
    t_check "check-env.sh rejects .env with mode 644" \
        bash -c '(( $1 != 0 )) && [[ "$2" == *"It must be 600"* ]]' _ "${T_RC}" "${T_OUT}"
    run_script update-env.sh
    t_check "update-env.sh restores mode 600 without changing content" \
        bash -c '[[ "$(stat -c %a "$1")" == 600 && "$(sha256sum < "$1")" == "$2" ]]' _ "${env_file}" "${before}"

    set_env_value "${env_file}" ADMIN_IP_ALLOWLIST "0.0.0.0/0"
    run_script check-env.sh
    t_check "check-env.sh rejects an allowlist for every address" \
        bash -c '(( $1 != 0 )) && [[ "$2" == *"must not allow every address"* ]]' _ "${T_RC}" "${T_OUT}"
    set_env_value "${env_file}" ADMIN_IP_ALLOWLIST "10.66.0.2/32"

    set_env_value "${env_file}" COMPOSE_PROJECT_NAME "tampered"
    run_script update-env.sh
    local backup
    backup="$(find "${stack}" -name '.env.bak-*' -print | head -n 1)"
    t_check "update-env.sh backs up before restoring a framework value" \
        bash -c '[[ -n "$1" && "$(stat -c %a "$1")" == 600 ]] && grep -qx "COMPOSE_PROJECT_NAME=tampered" "$1"' _ "${backup}"
    t_check "the framework value is restored" grep -qx 'COMPOSE_PROJECT_NAME=infrastructure-sjv' "${env_file}"
    run_script check-env.sh
    t_check "check-env.sh accepts private backups" bash -c '(( $1 == 0 )) && [[ "$2" == *"backup(s) are private"* ]]' _ "${T_RC}" "${T_OUT}"
    chmod 644 "${backup}"
    run_script check-env.sh
    t_check "check-env.sh rejects an open backup" bash -c '(( $1 != 0 )) && [[ "$2" == *"It must be 600"* ]]' _ "${T_RC}" "${T_OUT}"
    chmod 600 "${backup}"

    local lock_holder
    flock "${stack}/.env.lock" sleep 4 &
    lock_holder=$!
    sleep 0.5
    run_script update-env.sh
    t_check "update-env.sh refuses to run while another update holds the lock" \
        bash -c '(( $1 != 0 )) && [[ "$2" == *"Another process holds"* ]]' _ "${T_RC}" "${T_OUT}"
    wait "${lock_holder}" || true

    printf '%s\n' '# local edit' >> "${stack}/.env.example"
    run_script update-env.sh
    t_check "update-env.sh refuses a stale stack copy of .env.example" \
        bash -c '(( $1 != 0 )) && [[ "$2" == *"differs from Git"* ]]' _ "${T_RC}" "${T_OUT}"
    run_script init.sh
    t_check "init.sh restores the stack copy of .env.example" cmp -s "${ENV_EXAMPLE_FILE}" "${stack}/.env.example"
}

run_script_tests() {
    print_header "Scripts in test mode"
    T_BASE="${T_RUN_DIR}/base"
    mkdir -m 755 "${T_BASE}"
    test_scripts_guard
    test_scripts_init
    test_scripts_env
}
