#!/usr/bin/env bash
# The first matching pg_hba line wins. The peer map has to precede the general local rule.
set -euo pipefail

[[ -n "${PGDATA:-}" && -f "${PGDATA}/pg_hba.conf" ]] || {
    printf '%s\n' "PGDATA/pg_hba.conf is missing." >&2
    exit 1
}

hba="${PGDATA}/pg_hba.conf"
ident="${PGDATA}/pg_ident.conf"
rule='local sjv pgbackrest peer map=sjv-pgbackrest'
map='sjv-pgbackrest postgres pgbackrest'

if ! grep -qxF "${rule}" "${hba}"; then
    tmp="$(mktemp)"
    awk -v rule="${rule}" '
        BEGIN { done = 0 }
        done == 0 && $0 !~ /^[[:space:]]*#/ && $0 !~ /^[[:space:]]*$/ {
            print rule
            done = 1
        }
        { print }
        END {
            if (done == 0) print rule
        }
    ' "${hba}" > "${tmp}"
    cat "${tmp}" > "${hba}"
    rm -f "${tmp}"
fi

touch "${ident}"
grep -qxF "${map}" "${ident}" || printf '%s\n' "${map}" >> "${ident}"
