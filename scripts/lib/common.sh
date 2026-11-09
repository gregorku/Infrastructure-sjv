#!/usr/bin/env bash
# Shared checks for root, commands, mounts, private directories and locks.

require_root() {
    if [[ "${SJV_TEST_MODE}" -eq 1 ]]; then
        return 0
    fi
    [[ "${EUID}" -eq 0 ]] || fail "This script must be run as root inside the Incus container."
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

check_environment() {
    require_root
    local cmd
    for cmd in awk base64 cmp cp date find findmnt flock head install mktemp sort stat tr; do
        require_command "${cmd}"
    done
    ok "Environment OK."
}

require_mountpoint() {
    local path="$1"
    if [[ "${SJV_TEST_MODE}" -eq 1 ]]; then
        [[ -d "${path}" ]] || fail "${path} does not exist."
        info "Test mode: mountpoint check skipped for ${path}."
        return 0
    fi
    [[ -d "${path}" ]] || fail "${path} does not exist. This project does not create the Incus disk."
    findmnt -T "${path}" >/dev/null 2>&1 || fail "${path} is not a mount. Refusing to store data on the container root filesystem."
    local target
    target="$(findmnt -T "${path}" -n -o TARGET)"
    [[ "${target}" == "${path}" ]] || fail "${path} is not the mountpoint (findmnt reports ${target})."
}

file_mode() { stat -c '%a' "$1"; }
file_owner() { stat -c '%u' "$1"; }

# True for a real file and for a symlink, including one whose target is missing.
path_present() {
    [[ -e "$1" || -L "$1" ]]
}

# Creates a directory or checks an existing one. Fails on symlinks and on
# foreign owners. A directory that is too open is tightened, never loosened.
ensure_dir() {
    local path="$1" mode="$2"
    [[ "${path}" == /* && "${path}" != "/" && "${path}" != *..* ]] || fail "Unsafe directory path: ${path}"
    if [[ -L "${path}" ]]; then
        fail "${path} is a symlink. Refusing to use it."
    fi
    if [[ ! -e "${path}" ]]; then
        install -d -m "${mode}" "${path}"
        info "Created ${path} (mode ${mode})."
        return 0
    fi
    [[ -d "${path}" ]] || fail "${path} exists and is not a directory."
    [[ "$(file_owner "${path}")" == "${EUID}" ]] || fail "${path} is owned by uid $(file_owner "${path}"), expected ${EUID}."
    local current
    current="$(file_mode "${path}")"
    if (( (8#${current} & ~8#${mode}) != 0 )); then
        chmod "${mode}" "${path}"
        warn "${path} had mode ${current}. Tightened to ${mode}."
    fi
}

# Fails when a file holding secrets is readable by anyone but its owner.
assert_private_file() {
    local path="$1"
    [[ -f "${path}" && ! -L "${path}" ]] || fail "${path} is not a regular file."
    [[ "$(file_owner "${path}")" == "${EUID}" ]] || fail "${path} is owned by uid $(file_owner "${path}"), expected ${EUID}."
    local mode
    mode="$(file_mode "${path}")"
    [[ "${mode}" == "600" ]] || fail "${path} has mode ${mode}. It must be 600."
}

# Takes an exclusive lock for the rest of the calling process.
acquire_lock() {
    local lock_file="$1" wait_seconds="${2:-10}" fd
    [[ ! -L "${lock_file}" ]] || fail "Lock file ${lock_file} is a symlink."
    (umask 077 && : >> "${lock_file}")
    exec {fd}>>"${lock_file}"
    flock -w "${wait_seconds}" "${fd}" || fail "Another process holds ${lock_file}. Try again later."
}
