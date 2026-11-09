#!/usr/bin/env bash
# Runs the offline test suite. Needs no containers, network or root, and
# writes only to .test-tmp inside this checkout (removed afterwards).
set -Eeuo pipefail
shopt -s inherit_errexit
unset SJV_TEST_BASE_DIR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/config.sh
source "${SCRIPT_DIR}/config.sh"
# shellcheck source=scripts/lib/logging.sh
source "${SCRIPT_DIR}/lib/logging.sh"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/env/env.sh
source "${SCRIPT_DIR}/lib/env/env.sh"
# shellcheck source=scripts/lib/tests/assert.sh
source "${SCRIPT_DIR}/lib/tests/assert.sh"
# shellcheck source=scripts/lib/tests/test-static.sh
source "${SCRIPT_DIR}/lib/tests/test-static.sh"
# shellcheck source=scripts/lib/tests/test-env-lib.sh
source "${SCRIPT_DIR}/lib/tests/test-env-lib.sh"
# shellcheck source=scripts/lib/tests/test-scripts.sh
source "${SCRIPT_DIR}/lib/tests/test-scripts.sh"
# shellcheck source=scripts/lib/deploy/layout.sh
source "${SCRIPT_DIR}/lib/deploy/layout.sh"
# shellcheck source=scripts/lib/deploy/docker.sh
source "${SCRIPT_DIR}/lib/deploy/docker.sh"
# shellcheck source=scripts/lib/deploy/networks.sh
source "${SCRIPT_DIR}/lib/deploy/networks.sh"
# shellcheck source=scripts/lib/deploy/crowdsec.sh
source "${SCRIPT_DIR}/lib/deploy/crowdsec.sh"
# shellcheck source=scripts/lib/deploy/render.sh
source "${SCRIPT_DIR}/lib/deploy/render.sh"
# shellcheck source=scripts/lib/tests/test-infra.sh
source "${SCRIPT_DIR}/lib/tests/test-infra.sh"

T_RUN_DIR=""

cleanup_run_dir() {
    if [[ -n "${T_RUN_DIR}" && "${T_RUN_DIR}" == "${TEST_TMP_ROOT}"/run.* && ! -L "${T_RUN_DIR}" ]]; then
        rm -rf -- "${T_RUN_DIR}"
    fi
    rmdir -- "${TEST_TMP_ROOT}" 2>/dev/null || true
}

run_shellcheck_step() {
    print_header "ShellCheck"
    local rc=0
    "${SCRIPT_DIR}/shellcheck.sh" || rc=$?
    case "${rc}" in
        0) t_pass "shellcheck: no findings" ;;
        3) t_skip "shellcheck is not installed; run ./scripts/shellcheck.sh where it is available" ;;
        *) t_fail "shellcheck reported findings" ;;
    esac
}

main() {
    umask 077
    [[ ! -L "${TEST_TMP_ROOT}" ]] || fail "${TEST_TMP_ROOT} is a symlink."
    if [[ ! -d "${TEST_TMP_ROOT}" ]]; then
        mkdir -m 700 "${TEST_TMP_ROOT}"
    fi
    T_RUN_DIR="$(mktemp -d "${TEST_TMP_ROOT}/run.XXXXXX")"
    trap cleanup_run_dir EXIT
    mkdir -m 700 "${T_RUN_DIR}/tmp"
    export TMPDIR="${T_RUN_DIR}/tmp"

    run_static_tests
    run_env_lib_tests
    run_script_tests
    run_infra_tests
    run_shellcheck_step

    print_footer "No container, network, ZFS or host configuration was touched."
    t_summary
}

case "${1:---static}" in
    --static) main ;;
    --help)
        printf '%s\n' "Usage: ./scripts/test.sh [--static]" \
            "Runs syntax, static, environment-library and script tests offline."
        ;;
    *) fail "Unknown option: $1" ;;
esac
