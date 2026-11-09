#!/usr/bin/env bash
# Loads and validates the runtime .env for scripts that act on it.

declare -gA RUNTIME_ENV=()

# Usage: env_load_file FILE
# Checks ownership and mode, parses and validates. Prints every error, then
# fails. Warnings are printed but do not fail.
env_load_file() {
    local file="$1" message
    [[ -e "${file}" ]] || fail "Runtime .env is missing: ${file}. Run ./scripts/update-env.sh."
    assert_private_file "${file}"
    # shellcheck disable=SC2034 # read through the nameref inside env_parse_file
    RUNTIME_ENV=()
    env_parse_file "${file}" RUNTIME_ENV
    if ! env_validate RUNTIME_ENV; then
        for message in "${ENV_ERRORS[@]}"; do
            error "${message}"
        done
        fail "${file##*/} has ${#ENV_ERRORS[@]} problem(s)."
    fi
    for message in "${ENV_WARNINGS[@]}"; do
        warn "${message}"
    done
}

env_load_runtime() {
    env_load_file "${ENV_FILE}"
}
