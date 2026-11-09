#!/usr/bin/env bash
# Creates or updates the runtime .env from .env.example according to
# ENV_POLICY. The existing file is never edited in place: a new version is
# written next to it, compared, backed up and then moved over atomically.

ENV_SYNC_RESULT=""
ENV_SYNC_BACKUP_PATH=""
ENV_SYNC_TEMP_PATHS=()
ENV_SYNC_TEMP_INODES=()
readonly ENV_RETAINED_MARKER="# Retained by update-env.sh: these variables are not in .env.example."

# Remembers a temp file this process created. Cleanup deletes only a path
# whose inode is still the one we created, so another run's file is kept.
env_sync_track_temp() {
    local path="$1" inode
    inode="$(stat -c '%i' "${path}")"
    ENV_SYNC_TEMP_PATHS+=("${path}")
    ENV_SYNC_TEMP_INODES+=("${inode}")
}

env_sync_forget_temp() {
    local path="$1" i
    for i in "${!ENV_SYNC_TEMP_PATHS[@]}"; do
        if [[ "${ENV_SYNC_TEMP_PATHS[i]}" == "${path}" ]]; then
            ENV_SYNC_TEMP_PATHS[i]=""
            ENV_SYNC_TEMP_INODES[i]=""
        fi
    done
}

env_sync_drop_temps() {
    local i path now
    for i in "${!ENV_SYNC_TEMP_PATHS[@]}"; do
        path="${ENV_SYNC_TEMP_PATHS[i]}"
        [[ -n "${path}" && -f "${path}" && ! -L "${path}" ]] || continue
        now="$(stat -c '%i' "${path}" 2>/dev/null || true)"
        if [[ -n "${now}" && "${now}" == "${ENV_SYNC_TEMP_INODES[i]}" ]]; then
            rm -f -- "${path}"
        fi
    done
    return 0
}

# Removes our temp files, then dies with the signal that interrupted us.
env_sync_on_signal() {
    local sig="$1"
    trap - EXIT INT TERM HUP
    env_sync_drop_temps
    kill -s "${sig}" "${BASHPID}"
}

env_generate_secret() {
    local value
    value="$(head -c "${ENV_GENERATED_SECRET_BYTES}" /dev/urandom | base64 -w 0 | tr '+/' '-_' | tr -d '=')"
    (( ${#value} >= ENV_MIN_GENERATED_LENGTH )) || fail "Secret generator returned a short value."
    printf '%s\n' "${value}"
}

# Fails unless the example and ENV_POLICY describe exactly the same keys.
env_check_example_policy() {
    local example="$1" key
    local -A example_values=()
    env_parse_file "${example}" example_values
    for key in "${!example_values[@]}"; do
        [[ -v "ENV_POLICY[${key}]" ]] || fail "${example##*/} contains ${key}, which has no ENV_POLICY entry."
        if [[ "${ENV_POLICY[${key}]}" == generated ]] \
            && [[ -n "${example_values[${key}]}" ]] && ! env_is_placeholder "${example_values[${key}]}"; then
            fail "${example##*/} contains a real value for generated ${key}."
        fi
    done
    for key in "${!ENV_POLICY[@]}"; do
        [[ -v "example_values[${key}]" ]] || fail "ENV_POLICY lists ${key}, which is missing from ${example##*/}."
    done
}

env_assert_target_safe() {
    local target="$1" dir="${1%/*}"
    [[ -d "${dir}" && ! -L "${dir}" ]] || fail "Directory ${dir} does not exist or is a symlink."
    [[ "$(file_owner "${dir}")" == "${EUID}" ]] || fail "${dir} is not owned by uid ${EUID}."
    (( (8#$(file_mode "${dir}") & 8#022) == 0 )) || fail "${dir} is writable by the group or by others."
    if [[ -L "${target}" ]]; then
        fail "${target} is a symlink. Refusing to replace it."
    fi
    if [[ -e "${target}" ]]; then
        [[ -f "${target}" ]] || fail "${target} is not a regular file."
        [[ "$(file_owner "${target}")" == "${EUID}" ]] || fail "${target} is owned by uid $(file_owner "${target}"), expected ${EUID}."
    fi
}

# Keeps old backups private. Backups are never deleted automatically.
env_protect_backups() {
    local target="$1" file mode count=0
    while IFS= read -r -d '' file; do
        count=$((count + 1))
        if [[ -L "${file}" ]]; then
            warn "Backup ${file##*/} is a symlink. Inspect it manually."
            continue
        fi
        mode="$(file_mode "${file}")"
        if [[ "${mode}" != 600 ]]; then
            chmod 600 "${file}"
            warn "Backup ${file##*/} had mode ${mode}. Tightened to 600."
        fi
    done < <(find "${target%/*}" -maxdepth 1 -name "${target##*/}.bak-*" -print0)
    if (( count > ENV_BACKUP_WARN_COUNT )); then
        warn "${count} .env backups exist. Remove old ones manually after checking them."
    fi
}

# Copies TARGET to a new .env.bak-* file. The backup name appears only after
# the copy is mode 600, via rename in the same directory. Sets
# ENV_SYNC_BACKUP_PATH. The source file is only read.
env_backup_file() {
    local target="$1" backup suffix=0 staging
    backup="${target}.bak-$(date -u +%Y%m%dT%H%M%SZ)"
    while [[ -e "${backup}" || -L "${backup}" ]]; do
        suffix=$((suffix + 1))
        backup="${target}.bak-$(date -u +%Y%m%dT%H%M%SZ)-${suffix}"
    done
    [[ -f "${target}" && ! -L "${target}" ]] || fail "${target} is not a regular file. Nothing was changed."
    staging="$(umask 077 && mktemp "${target%/*}/.env.tmp.XXXXXX")"
    env_sync_track_temp "${staging}"
    if ! cat < "${target}" > "${staging}"; then
        env_sync_drop_temps
        fail "Could not copy ${target##*/} for backup. Nothing was changed."
    fi
    chmod 600 "${staging}"
    if ! cmp -s "${target}" "${staging}"; then
        env_sync_drop_temps
        fail "Backup copy does not match ${target##*/}. Nothing was changed."
    fi
    # mv -n leaves the staging file in place when the destination exists.
    mv -n -- "${staging}" "${backup}"
    if [[ -e "${staging}" || -L "${staging}" ]]; then
        env_sync_drop_temps
        fail "Backup name ${backup##*/} appeared during the copy. Nothing was changed."
    fi
    env_sync_forget_temp "${staging}"
    ENV_SYNC_BACKUP_PATH="${backup}"
}

# Usage: env_sync_file EXAMPLE TARGET
# Sets ENV_SYNC_RESULT to created, updated or unchanged.
env_sync_file() {
    local example="$1" target="$2"
    local line key value policy existing
    local -A current=()
    local -a out=() kept=() generated=() added=() framework_changed=() retained=()

    [[ -f "${example}" && ! -L "${example}" ]] || fail "Missing ${example}"
    env_check_example_policy "${example}"
    env_assert_target_safe "${target}"
    if [[ -f "${target}" ]]; then
        env_parse_file "${target}" current
    fi

    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# || "${line}" != *=* ]]; then
            out+=("${line}")
            continue
        fi
        key="${line%%=*}"
        value="${line#*=}"
        policy="${ENV_POLICY[${key}]}"
        if [[ -v "current[${key}]" ]]; then
            existing="${current[${key}]}"
        else
            existing=""
        fi
        case "${policy}" in
            framework)
                if [[ -v "current[${key}]" && "${existing}" != "${value}" ]]; then
                    framework_changed+=("${key}")
                elif [[ ! -v "current[${key}]" ]]; then
                    added+=("${key}")
                fi
                ;;
            user)
                if [[ -v "current[${key}]" ]]; then
                    value="${existing}"
                    kept+=("${key}")
                else
                    added+=("${key}")
                fi
                ;;
            generated)
                if [[ -n "${existing}" ]] && ! env_is_placeholder "${existing}"; then
                    value="${existing}"
                    kept+=("${key}")
                else
                    value="$(env_generate_secret)"
                    generated+=("${key}")
                fi
                ;;
            *) fail "Unknown policy for ${key}." ;;
        esac
        out+=("${key}=${value}")
    done < "${example}"

    if [[ -f "${target}" ]]; then
        while IFS= read -r key; do
            [[ -v "ENV_POLICY[${key}]" ]] && continue
            retained+=("${key}")
        done < <(env_keys_in_order "${target}")
        if (( ${#retained[@]} > 0 )); then
            out+=("" "${ENV_RETAINED_MARKER}")
            for key in "${retained[@]}"; do
                out+=("${key}=${current[${key}]}")
            done
        fi
    fi

    if [[ -f "${target}" ]] && cmp -s "${target}" <(printf '%s\n' "${out[@]}"); then
        if [[ "$(file_mode "${target}")" != 600 ]]; then
            warn "${target##*/} had mode $(file_mode "${target}"). Tightened to 600."
            chmod 600 "${target}"
        fi
        env_protect_backups "${target}"
        ENV_SYNC_RESULT="unchanged"
        ok "${target##*/} is already up to date. The file was not rewritten."
        return 0
    fi

    # The write runs in a subshell so its signal trap cannot replace the
    # caller's trap. Temps are removed on error, EXIT, INT, TERM and HUP.
    # A finished rename is forgotten, so cleanup does not touch .env or a
    # temp file created by another run. Stdout is only the backup path.
    local commit_note
    commit_note="$(
        set -Eeuo pipefail
        local tmp
        ENV_SYNC_TEMP_PATHS=()
        ENV_SYNC_TEMP_INODES=()
        ENV_SYNC_BACKUP_PATH=""
        trap env_sync_drop_temps EXIT
        trap 'env_sync_on_signal INT' INT
        trap 'env_sync_on_signal TERM' TERM
        trap 'env_sync_on_signal HUP' HUP
        tmp="$(umask 077 && mktemp "${target%/*}/.env.tmp.XXXXXX")"
        env_sync_track_temp "${tmp}"
        printf '%s\n' "${out[@]}" > "${tmp}"
        chmod 600 "${tmp}"
        if [[ -f "${target}" ]]; then
            env_backup_file "${target}"
        fi
        mv -f -- "${tmp}" "${target}"
        env_sync_forget_temp "${tmp}"
        if [[ -n "${ENV_SYNC_BACKUP_PATH}" ]]; then
            printf '%s\n' "${ENV_SYNC_BACKUP_PATH}"
        fi
    )" || exit $?
    if [[ -n "${commit_note}" ]]; then
        info "Backup written: ${commit_note##*/} (mode 600)."
        ENV_SYNC_RESULT="updated"
    else
        ENV_SYNC_RESULT="created"
    fi
    chmod 600 "${target}"
    env_protect_backups "${target}"

    ok "${target##*/} ${ENV_SYNC_RESULT} (mode 600)."
    (( ${#generated[@]} == 0 )) || info "Generated (values not shown): ${generated[*]}"
    (( ${#added[@]} == 0 )) || info "Added from .env.example: ${added[*]}"
    (( ${#framework_changed[@]} == 0 )) || info "Framework values updated: ${framework_changed[*]}"
    (( ${#retained[@]} == 0 )) || warn "Kept variables that .env.example no longer has: ${retained[*]}. check-env.sh rejects them until they are removed."
}

# Prints the names of keys that still hold a placeholder.
env_list_placeholders() {
    local file="$1" key
    local -A values=()
    env_parse_file "${file}" values
    while IFS= read -r key; do
        if env_is_placeholder "${values[${key}]}"; then
            printf '%s\n' "${key}"
        fi
    done < <(env_keys_in_order "${file}")
}
