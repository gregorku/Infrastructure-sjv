#!/usr/bin/env bash
# Host directory layout and copying of secret-free files from Git into the
# stack directory. Persistent data is never removed or overwritten here.

assert_layout_paths() {
    local path
    for path in "${GIT_DIR}" "${STACK_DIR}" "${DATA_DIR}" "${BACKUP_LOCAL_DIR}"; do
        [[ -n "${path}" && "${path}" == /* && "${path}" != "/" && "${path}" != *..* ]] \
            || fail "Unsafe project path: ${path:-<empty>}"
    done
    [[ "${STACK_DIR}" == "${STACKS_DIR}/${STACK_NAME}" ]] || fail "STACK_DIR is not under this project's stack name."
    case "${GIT_DIR}" in
        "${BASE_DIR}"/stacks|"${BASE_DIR}"/stacks/*|"${DATA_DIR}"|"${DATA_DIR}"/*|"${BACKUP_LOCAL_DIR}"|"${BACKUP_LOCAL_DIR}"/*)
            fail "The Git checkout must not live inside the stack, data or backup directory."
            ;;
    esac
    [[ "${DATA_DIR}" != "${STACK_DIR}" && "${BACKUP_LOCAL_DIR}" != "${STACK_DIR}" ]] \
        || fail "Data and backups must stay outside the stack directory."
    if [[ "${SJV_TEST_MODE}" -eq 0 ]]; then
        case "${BASE_DIR}" in
            "${GIT_DIR}"|"${GIT_DIR}"/*) fail "Runtime data must not live inside the Git checkout." ;;
        esac
    fi
}

# Creates one private file. An existing file is kept and must already be mode 600.
layout_prepare_acme() {
    local old_umask
    [[ ! -L "${ACME_FILE}" ]] || fail "${ACME_FILE} is a symlink. Refusing to replace it."
    if [[ ! -e "${ACME_FILE}" ]]; then
        old_umask="$(umask)"
        umask 077
        : > "${ACME_FILE}"
        chmod 600 "${ACME_FILE}"
        umask "${old_umask}"
        info "Created ${ACME_FILE} (mode 600)."
    fi
    [[ -f "${ACME_FILE}" ]] || fail "${ACME_FILE} is not a regular file."
    [[ "$(file_mode "${ACME_FILE}")" == 600 ]] || fail "${ACME_FILE} has mode $(file_mode "${ACME_FILE}"). It must be 600."
}

# Creates an empty access.log so CrowdSec can open /logs/access.log on its
# first start. An existing regular file is left unchanged. A symlink is
# refused and is not followed. noclobber avoids truncating a file that
# appears between the check and the create.
layout_prepare_access_log() {
    local dir="${TRAEFIK_DIR}/logs" live="${TRAEFIK_DIR}/logs/access.log"
    [[ "${dir}" == /* && "${dir}" != "/" && "${dir}" != *..* ]] || fail "Unsafe log directory."
    [[ -d "${dir}" && ! -L "${dir}" ]] || fail "Traefik log directory is missing or is a symlink."
    [[ "$(cd -- "${dir}" && pwd -P)" == "${dir}" ]] || fail "Traefik log directory is not a canonical path."
    if path_present "${live}"; then
        layout_keep_access_log "${live}"
        return 0
    fi
    if ! (umask 137 && set -o noclobber && : > "${live}"); then
        layout_keep_access_log "${live}"
        return 0
    fi
    chmod 640 "${live}"
    [[ -f "${live}" && ! -L "${live}" ]] || fail "access.log is not a regular file."
    [[ ! -s "${live}" ]] || fail "A new access.log was not empty."
    [[ "$(file_mode "${live}")" == "640" ]] || fail "access.log has mode $(file_mode "${live}"). It must be 640."
    [[ "$(file_owner "${live}")" == "${EUID}" ]] || fail "access.log is owned by uid $(file_owner "${live}"), expected ${EUID}."
    info "Created ${live} (mode 640)."
}

layout_keep_access_log() {
    local live="$1"
    [[ ! -L "${live}" ]] || fail "access.log is a symlink. Refusing to replace it."
    [[ -f "${live}" ]] || fail "access.log exists and is not a regular file."
    [[ "$(file_owner "${live}")" == "${EUID}" ]] || fail "access.log is owned by uid $(file_owner "${live}"), expected ${EUID}."
    [[ "$(readlink -f -- "${live}")" == "${live}" ]] || fail "access.log resolves outside the log directory."
    info "access.log already exists. Its contents were not changed."
}

# Root keeps ownership so a later init still accepts the directory. Group 999
# is the postgres group inside the official image. ensure_dir never loosens a
# mode, so the group write bit is applied here on purpose.
layout_prepare_postgres_mount() {
    local path="$1" group
    ensure_dir "${path}" 2770
    if [[ "$(file_mode "${path}")" != "2770" ]]; then
        chmod 2770 "${path}"
        info "Mode of ${path} set to 2770."
    fi
    if [[ "${EUID}" -eq 0 ]]; then
        group="$(stat -c %g "${path}")"
        if [[ "${group}" != "999" ]]; then
            chgrp 999 "${path}"
            info "Group of ${path} set to 999."
        fi
    fi
}

# Directories created by init.sh. The PostgreSQL mount stays owned by root.
# Mode 2770 and, when init runs as root, group 999 let the official image
# user (uid/gid 999) create its data directory inside the mount. The parent
# backup directory stays mode 700, so a host process cannot walk in from
# outside. Mosquitto stays out until its stage. Traefik and CrowdSec
# directories hold no bouncer key yet.
layout_prepare() {
    print_section "Directory layout"
    assert_layout_paths
    ensure_dir "${STACKS_DIR}" 755
    ensure_dir "${STACK_DIR}" 750
    ensure_dir "${DATA_DIR}" 755
    ensure_dir "${STATE_DIR}" 700
    ensure_dir "${SECRETS_DIR}" 700
    ensure_dir "${BASE_DIR}/backups" 755
    ensure_dir "${BACKUP_LOCAL_DIR}" 700
    layout_prepare_postgres_mount "${BACKUP_LOCAL_DIR}/pgbackrest"
    layout_prepare_postgres_mount "${BACKUP_LOCAL_DIR}/pgbackrest/archive"
    ensure_dir "${BACKUP_LOCAL_DIR}/dumps" 700
    ensure_dir "${BACKUP_LOCAL_DIR}/files" 700
    ensure_dir "${BACKUP_LOCAL_DIR}/preparations" 700
    ensure_dir "${DATA_DIR}/backup-locks" 700
    layout_prepare_postgres_mount "${POSTGRES_DIR}"
    ensure_dir "${TRAEFIK_DIR}" 755
    ensure_dir "${TRAEFIK_DIR}/acme" 700
    ensure_dir "${TRAEFIK_DIR}/logs" 755
    ensure_dir "${TRAEFIK_DIR}/plugins" 755
    ensure_dir "${TRAEFIK_DIR}/users" 700
    ensure_dir "${TRAEFIK_DIR}/crowdsec" 700
    ensure_dir "${CROWDSEC_DIR}" 755
    ensure_dir "${CROWDSEC_DIR}/data" 700
    layout_prepare_acme
    ok "Directory layout is in place."
}

# Copies one secret-free file. The destination is left untouched when the
# bytes already match, so a repeated init does not change inodes or mtimes.
layout_copy_file() {
    local src="$1" dst="$2" rel="${3}"
    [[ -f "${src}" && ! -L "${src}" ]] || fail "Missing deployment file: ${src}"
    [[ "${dst}" == "${STACK_DIR}/"* && "${dst}" != *..* ]] || fail "Refusing to copy outside the stack directory."
    [[ ! -e "${dst}" || ! -L "${dst}" ]] || fail "${dst} is a symlink. Refusing to replace it."
    if [[ -f "${dst}" ]] && cmp -s "${src}" "${dst}"; then
        info "Unchanged ${rel}"
        return 0
    fi
    [[ -d "${dst%/*}" ]] || install -d -m 755 "${dst%/*}"
    install -m 644 "${src}" "${dst}"
    info "Synchronized ${rel}"
}

# Copies DEPLOY_ITEMS into STACK_DIR. A file is rewritten only when its
# content differs, so repeated runs do not touch unchanged files.
layout_sync_stack() {
    print_section "Synchronize stack files"
    assert_layout_paths
    local item src dst file rel
    for item in "${DEPLOY_ITEMS[@]}"; do
        [[ "${item}" != /* && "${item}" != *..* && "${item}" != .env ]] || fail "DEPLOY_ITEMS entry is not safe: ${item}"
        src="${GIT_DIR}/${item}"
        dst="${STACK_DIR}/${item}"
        if [[ -d "${src}" && ! -L "${src}" ]]; then
            while IFS= read -r file; do
                rel="${file#"${src}/"}"
                [[ -n "${rel}" && "${rel}" != *..* ]] || fail "Deployment file is not safe: ${file}"
                layout_copy_file "${file}" "${dst}/${rel}" "${item}/${rel}"
            done < <(find "${src}" -type f -print | sort)
        else
            layout_copy_file "${src}" "${dst}" "${item}"
        fi
    done
    ok "Stack files synchronized. Runtime .env and data were not touched."
}
