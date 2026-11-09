#!/usr/bin/env bash
# Rotation of Traefik's file logs.
# traefik.log is rotated inside Traefik (maxSize, maxAge, maxBackups). An
# external rename would leave Traefik writing into the renamed inode, and
# USR1 does not reopen that file.
# access.log has no built-in rotation. copytruncate keeps the inode, so
# Traefik's open descriptor and CrowdSec's inotify watch stay on
# /logs/access.log. Lines written between the copy and the truncate can be
# lost; that window is the cost of not renaming the file.

# shellcheck disable=SC2329 # cleanup runs from the EXIT trap
log_rotate_cleanup() {
    [[ "${LOG_ROTATE_COMMITTED:-0}" -eq 1 ]] && return 0
    if [[ -n "${LOG_ROTATE_COPY:-}" ]]; then
        rm -f -- "${LOG_ROTATE_COPY}"
    fi
    if [[ -n "${LOG_ROTATE_PARTIAL:-}" ]]; then
        rm -f -- "${LOG_ROTATE_PARTIAL}"
    fi
}

log_rotate_due() {
    local size="$1" mtime="$2" now="$3" force="$4" age
    [[ "${size}" =~ ^[0-9]+$ && "${mtime}" =~ ^[0-9]+$ && "${now}" =~ ^[0-9]+$ ]] || return 1
    if (( size == 0 )); then
        return 1
    fi
    if [[ "${force}" == 1 ]]; then
        return 0
    fi
    if (( size >= ACCESS_LOG_ROTATE_MIN_BYTES )); then
        return 0
    fi
    age=$((now - mtime))
    if (( age >= ACCESS_LOG_ROTATE_MAX_AGE )); then
        return 0
    fi
    return 1
}

log_rotate_prune() {
    local dir="$1" path base
    local -a files=()
    [[ "${dir}" == "${TRAEFIK_DIR}/logs" && "${dir}" != *..* ]] || fail "Refusing to prune outside the Traefik log directory."
    while IFS= read -r path; do
        [[ -n "${path}" ]] || continue
        base="${path##*/}"
        [[ "${base}" =~ ^access\.log\.[0-9]{8}T[0-9]{6}Z\.gz$ ]] || continue
        [[ "${path}" == "${dir}/${base}" && -f "${path}" && ! -L "${path}" ]] || fail "Refusing to touch unexpected archive ${path}."
        files+=("${path}")
    done < <(find "${dir}" -maxdepth 1 -type f -name 'access.log.*.gz' -printf '%T@ %p\n' | sort -n | cut -d' ' -f2-)
    local extra=$(( ${#files[@]} - ACCESS_LOG_ROTATE_KEEP ))
    local i
    if (( extra <= 0 )); then
        return 0
    fi
    for (( i = 0; i < extra; i++ )); do
        rm -f -- "${files[${i}]}"
        info "Removed old archive ${files[${i}]##*/}"
    done
}

log_rotate_access() {
    local force="$1" dir="${TRAEFIK_DIR}/logs" live="${TRAEFIK_DIR}/logs/access.log"
    local size mtime now mode owner inode stamp archive
    LOG_ROTATE_COMMITTED=0
    LOG_ROTATE_COPY=""
    LOG_ROTATE_PARTIAL=""
    [[ "${dir}" == /* && "${dir}" != "/" && "${dir}" != *..* ]] || fail "Unsafe log directory."
    [[ -d "${dir}" && ! -L "${dir}" ]] || fail "Traefik log directory is missing or is a symlink."
    [[ "$(cd -- "${dir}" && pwd -P)" == "${dir}" ]] || fail "Traefik log directory is not a canonical path."
    if [[ ! -e "${live}" && ! -L "${live}" ]]; then
        info "access.log does not exist yet. Nothing was rotated."
        log_rotate_prune "${dir}"
        return 0
    fi
    [[ -f "${live}" && ! -L "${live}" ]] || fail "access.log is not a regular file. It was not rotated."
    [[ "$(readlink -f -- "${live}")" == "${live}" ]] || fail "access.log resolves outside the log directory."
    size="$(stat -c '%s' "${live}")"
    mtime="$(stat -c '%Y' "${live}")"
    now="$(date -u +%s)"
    mode="$(stat -c '%a' "${live}")"
    owner="$(stat -c '%u:%g' "${live}")"
    inode="$(stat -c '%i' "${live}")"
    if ! log_rotate_due "${size}" "${mtime}" "${now}" "${force}"; then
        info "access.log does not need rotation."
        log_rotate_prune "${dir}"
        return 0
    fi
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    [[ "${stamp}" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || fail "Rotation timestamp is not UTC."
    archive="${dir}/access.log.${stamp}.gz"
    [[ "${archive}" == "${dir}/access.log.${stamp}.gz" ]] || fail "Archive path is not inside the log directory."
    [[ ! -e "${archive}" && ! -L "${archive}" ]] || fail "Archive ${archive##*/} already exists. Nothing was truncated."
    LOG_ROTATE_COPY="$(mktemp "${dir}/.access-rotate.XXXXXX")"
    LOG_ROTATE_PARTIAL="${dir}/.access-rotate.${stamp}.partial"
    [[ ! -e "${LOG_ROTATE_PARTIAL}" && ! -L "${LOG_ROTATE_PARTIAL}" ]] || fail "A partial archive already exists. Nothing was truncated."
    cp -a -- "${live}" "${LOG_ROTATE_COPY}"
    gzip -c -n -- "${LOG_ROTATE_COPY}" > "${LOG_ROTATE_PARTIAL}"
    sync -f -- "${LOG_ROTATE_PARTIAL}"
    chmod 640 "${LOG_ROTATE_PARTIAL}"
    mv -f -- "${LOG_ROTATE_PARTIAL}" "${archive}"
    LOG_ROTATE_PARTIAL=""
    LOG_ROTATE_COMMITTED=1
    rm -f -- "${LOG_ROTATE_COPY}"
    LOG_ROTATE_COPY=""
    truncate -s 0 -- "${live}"
    [[ "$(stat -c '%i' "${live}")" == "${inode}" ]] || fail "access.log inode changed during rotation."
    [[ "$(stat -c '%a' "${live}")" == "${mode}" ]] || fail "access.log mode changed during rotation."
    [[ "$(stat -c '%u:%g' "${live}")" == "${owner}" ]] || fail "access.log owner changed during rotation."
    [[ -f "${live}" && ! -L "${live}" ]] || fail "access.log is no longer a regular file."
    ok "Rotated access.log to ${archive##*/}. The live file kept its inode."
    log_rotate_prune "${dir}"
}
