#!/usr/bin/env bash
# Minimal test helpers. A failed assertion is recorded and the run continues,
# so one report lists every failure.

T_PASS=0
T_FAIL=0
T_SKIP=0
T_OUT=""
T_RC=0
declare -a T_FAILED=()
declare -a T_SKIPPED=()

t_pass() { T_PASS=$((T_PASS + 1)); ok "$1"; }
t_fail() { T_FAIL=$((T_FAIL + 1)); T_FAILED+=("$1"); error "FAIL: $1"; }
t_skip() { T_SKIP=$((T_SKIP + 1)); T_SKIPPED+=("$1"); warn "SKIP: $1"; }

# Usage: t_check NAME COMMAND [ARGS...]
t_check() {
    local name="$1"
    shift
    if "$@"; then
        t_pass "${name}"
    else
        t_fail "${name}"
    fi
}

# Runs a command in a subshell with errexit, capturing output and status.
t_run() {
    set +e
    T_OUT="$(set -Eeuo pipefail; "$@" 2>&1)"
    T_RC=$?
    set -e
}

# Usage: t_expect_ok NAME COMMAND [ARGS...]
t_expect_ok() {
    local name="$1"
    shift
    t_run "$@"
    if (( T_RC == 0 )); then
        t_pass "${name}"
    else
        t_fail "${name} (exit ${T_RC}): ${T_OUT##*$'\n'}"
    fi
}

# Usage: t_expect_fail NAME EXPECTED_TEXT COMMAND [ARGS...]
# EXPECTED_TEXT may be empty when only the failure matters.
t_expect_fail() {
    local name="$1" expected="$2"
    shift 2
    t_run "$@"
    if (( T_RC == 0 )); then
        t_fail "${name}: command succeeded"
    elif [[ -n "${expected}" && "${T_OUT}" != *"${expected}"* ]]; then
        t_fail "${name}: missing message '${expected}'"
    else
        t_pass "${name}"
    fi
}

t_contains() { [[ "$1" == *"$2"* ]]; }
t_not_contains() { [[ "$1" != *"$2"* ]]; }

# Fails when any of the listed secret values appears in TEXT.
t_no_secret_in() {
    local text="$1" secret
    shift
    for secret in "$@"; do
        [[ -n "${secret}" ]] || continue
        [[ "${text}" != *"${secret}"* ]] || return 1
    done
}

t_summary() {
    printf '\n%s\n' "Test summary: ${T_PASS} passed, ${T_FAIL} failed, ${T_SKIP} skipped."
    local item
    for item in "${T_SKIPPED[@]}"; do
        printf '  skipped: %s\n' "${item}"
    done
    for item in "${T_FAILED[@]}"; do
        printf '  failed:  %s\n' "${item}"
    done
    (( T_FAIL == 0 ))
}
