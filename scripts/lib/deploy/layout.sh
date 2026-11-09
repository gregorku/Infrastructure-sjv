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

# Directories created by init.sh. PostgreSQL and Mosquitto stay out until
# their stages. Traefik and CrowdSec directories hold no bouncer key yet.
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
    ensure_dir "${TRAEFIK_DIR}" 755
    ensure_dir "${TRAEFIK_DIR}/acme" 700
    ensure_dir "${TRAEFIK_DIR}/logs" 755
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
