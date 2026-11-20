#!/usr/bin/env bash
# Stop role creation when a password is missing or still a template placeholder.
# The values are not printed.
set -euo pipefail

names=(
    POSTGRES_SJV_OWNER_PASSWORD
    POSTGRES_SJV_API_PASSWORD
    POSTGRES_SJV_COLLECTOR_PASSWORD
    POSTGRES_SJV_WORKER_PASSWORD
    POSTGRES_SJV_MAINTENANCE_PASSWORD
    POSTGRES_SJV_READONLY_PASSWORD
)
for name in "${names[@]}"; do
    value="${!name-}"
    if [[ -z "${value}" || "${value}" == set_* ]]; then
        printf '%s\n' "Role init refused: ${name} is missing or still a placeholder." >&2
        exit 1
    fi
    unset value
done
