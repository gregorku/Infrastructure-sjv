#!/usr/bin/env bash
# Output helpers. Messages must never contain secret values; callers pass
# variable names, not their contents.

info() { printf '  %b\n' "${COLOR_BLUE:-}*${COLOR_RESET:-} $*"; }
ok() { printf '  %b\n' "${COLOR_GREEN:-}+${COLOR_RESET:-} $*"; }
warn() { printf '  %b\n' "${COLOR_YELLOW:-}!${COLOR_RESET:-} $*" >&2; }
error() { printf '  %b\n' "${COLOR_RED:-}x${COLOR_RESET:-} $*" >&2; }
fail() { error "$*"; exit 1; }

print_header() {
    printf '\n%s\n%s\n' "$1" "--------------------------------------------------------------------------------"
}

print_section() {
    printf '\n-- %s\n' "$1"
}

print_footer() {
    printf '\n%s\n' "$1"
}

# Reports where an unexpected command failed. Only the script and line are
# printed: the failing command text could contain an expanded secret.
log_install_err_trap() {
    trap 'log_on_err "$?" "${BASH_SOURCE[0]:-?}" "${LINENO}"' ERR
}

log_on_err() {
    local code="$1" source="$2" line="$3"
    error "Unexpected failure (exit ${code}) in ${source##*/} at line ${line}."
}
