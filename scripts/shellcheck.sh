#!/usr/bin/env bash
# Runs ShellCheck on every shell file. Exit codes: 0 clean, 1 findings,
# 3 ShellCheck is not installed (nothing was checked).
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if ! command -v shellcheck >/dev/null 2>&1; then
    printf '%s\n' "shellcheck is not installed. Nothing was checked." >&2
    exit 3
fi

mapfile -t files < <(find "${REPO_ROOT}/scripts" -type f -name '*.sh' -print | sort)
cd "${REPO_ROOT}"
if shellcheck --shell=bash --severity=style --external-sources --source-path=SCRIPTDIR "${files[@]}"; then
    printf '%s\n' "shellcheck: ${#files[@]} files, no findings."
else
    exit 1
fi
