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

# Directories created by init.sh. Service-specific directories (PostgreSQL,
# Mosquitto, Traefik) are added by the stages that introduce those services.
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
    ok "Directory layout is in place."
}

# Copies DEPLOY_ITEMS into STACK_DIR. A file is rewritten only when its
# content differs, so repeated runs do not touch unchanged files.
layout_sync_stack() {
    print_section "Synchronize stack files"
    assert_layout_paths
    local item src dst
    for item in "${DEPLOY_ITEMS[@]}"; do
        [[ "${item}" != /* && "${item}" != *..* && "${item}" != .env ]] || fail "DEPLOY_ITEMS entry is not safe: ${item}"
        src="${GIT_DIR}/${item}"
        dst="${STACK_DIR}/${item}"
        [[ -f "${src}" && ! -L "${src}" ]] || fail "Missing deployment file: ${src}"
        [[ ! -L "${dst}" ]] || fail "${dst} is a symlink. Refusing to replace it."
        if [[ -f "${dst}" ]] && cmp -s "${src}" "${dst}"; then
            info "Unchanged ${item}"
            continue
        fi
        install -m 644 "${src}" "${dst}"
        info "Synchronized ${item}"
    done
    ok "Stack files synchronized. Runtime .env and data were not touched."
}
