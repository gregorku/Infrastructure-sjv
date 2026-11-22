#!/usr/bin/env bash
# Creates one new app-kek. An existing file is left unchanged.
# The key bytes are never printed.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/config.sh
source "${SCRIPT_DIR}/config.sh"
# shellcheck source=scripts/lib/logging.sh
source "${SCRIPT_DIR}/lib/logging.sh"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
log_install_err_trap

tmp=""
cleanup_tmp() {
    if [[ -n "${tmp}" && -f "${tmp}" && ! -L "${tmp}" ]]; then
        rm -f -- "${tmp}"
    fi
}
trap cleanup_tmp EXIT

case "${1:-}" in
    --help)
        printf '%s\n' "Usage: ./scripts/create-app-kek.sh PATH" \
            "Writes 32 random bytes to PATH with mode 600." \
            "Refuses when PATH already exists. The key is not printed." \
            "Production path: ${PRODUCTION_DATA_DIR}/secrets/app-kek"
        exit 0
        ;;
    "")
        fail "Usage: ./scripts/create-app-kek.sh PATH"
        ;;
    -*)
        fail "Unknown option: $1"
        ;;
esac
[[ "$#" -eq 1 ]] || fail "Usage: ./scripts/create-app-kek.sh PATH"
target="$1"
if [[ -L "${target}" || -d "${target}" ]]; then
    fail "Refusing to replace ${target}."
fi
if [[ -e "${target}" ]]; then
    fail "app-kek already exists and was not overwritten."
fi
parent="$(dirname -- "${target}")"
if [[ -L "${parent}" || ! -d "${parent}" ]]; then
    fail "The destination directory is missing."
fi
umask 077
tmp="$(mktemp "${parent}/.app-kek.XXXXXXXX")"
dd if=/dev/urandom of="${tmp}" bs=32 count=1 status=none conv=notrunc
chmod 600 -- "${tmp}"
if [[ "$(stat -c %s -- "${tmp}")" -ne 32 ]]; then
    fail "app-kek was not written."
fi
mv -n -- "${tmp}" "${target}"
if [[ -e "${tmp}" ]]; then
    fail "app-kek already exists and was not overwritten."
fi
tmp=""
if [[ -L "${target}" || ! -f "${target}" ]]; then
    fail "app-kek was not written."
fi
if [[ "$(stat -c %s -- "${target}")" -ne 32 || "$(stat -c %a -- "${target}")" != "600" ]]; then
    fail "app-kek was not written."
fi
ok "app-kek created with mode 600. The key was not printed."
