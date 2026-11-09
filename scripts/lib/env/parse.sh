#!/usr/bin/env bash
# Strict KEY=VALUE parser. Values are stored as plain data and are never
# evaluated by the shell.

# Prints one reason and returns 1 when a value is unsafe for a Compose .env.
env_value_unsafe_reason() {
    local value="$1"
    case "${value}" in
        *$'\r'*) printf '%s\n' "contains a carriage return (Windows line ending)" ;;
        *'$'*) printf '%s\n' "contains \$, which Docker Compose would interpolate" ;;
        *'`'*) printf '%s\n' "contains a backtick" ;;
        *'"'*|*"'"*) printf '%s\n' "contains a quote; values must be written without quotes" ;;
        *\\*) printf '%s\n' "contains a backslash" ;;
        *'#'*) printf '%s\n' "contains #, which Docker Compose may treat as a comment" ;;
        [[:space:]]*|*[[:space:]]) printf '%s\n' "has leading or trailing whitespace" ;;
        *) return 1 ;;
    esac
    return 0
}

# Usage: env_parse_file FILE ARRAY_NAME
# Fills the associative array ARRAY_NAME. Fails on any malformed line,
# duplicate key or unsafe value. Error messages name keys, never values.
env_parse_file() {
    local file="$1"
    local -n env_parse_target="$2"
    local line key value reason line_no=0
    [[ -f "${file}" ]] || fail "Missing env file: ${file}"
    [[ ! -L "${file}" ]] || fail "Env file ${file} is a symlink."
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line_no=$((line_no + 1))
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
        if [[ "${line}" != *=* ]]; then
            fail "${file##*/} line ${line_no}: not a KEY=VALUE assignment."
        fi
        key="${line%%=*}"
        value="${line#*=}"
        [[ "${key}" =~ ^[A-Z][A-Z0-9_]*$ ]] || fail "${file##*/} line ${line_no}: invalid variable name."
        if [[ -v "env_parse_target[${key}]" ]]; then
            fail "${file##*/} line ${line_no}: duplicate variable ${key}."
        fi
        if reason="$(env_value_unsafe_reason "${value}")"; then
            fail "${file##*/} line ${line_no}: ${key} ${reason}."
        fi
        env_parse_target["${key}"]="${value}"
    done < "${file}"
}

# Prints keys of a file in their original order.
env_keys_in_order() {
    local file="$1" line
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# || "${line}" != *=* ]] && continue
        printf '%s\n' "${line%%=*}"
    done < "${file}"
}
