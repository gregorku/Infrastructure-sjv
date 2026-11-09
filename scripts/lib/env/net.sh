#!/usr/bin/env bash
# IPv4 and CIDR helpers used by the validator. Pure functions, no output
# except the computed value.

env_ipv4_ok() {
    local ip="$1" octet
    [[ "${ip}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for octet in "${BASH_REMATCH[@]:1}"; do
        [[ "${octet}" == 0 || "${octet}" != 0* ]] || return 1
        (( 10#${octet} <= 255 )) || return 1
    done
}

env_ipv4_to_int() {
    local a b c d
    IFS=. read -r a b c d <<< "$1"
    printf '%s\n' $(( (10#${a} << 24) + (10#${b} << 16) + (10#${c} << 8) + 10#${d} ))
}

env_cidr_ok() {
    local cidr="$1" address prefix
    [[ "${cidr}" =~ ^([^/]+)/([0-9]{1,2})$ ]] || return 1
    address="${BASH_REMATCH[1]}"
    prefix="${BASH_REMATCH[2]}"
    [[ "${prefix}" == 0 || "${prefix}" != 0* ]] || return 1
    env_ipv4_ok "${address}" || return 1
    (( 10#${prefix} <= 32 ))
}

env_cidr_mask() {
    local prefix="$1"
    if (( prefix == 0 )); then
        printf '%s\n' 0
    else
        printf '%s\n' $(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    fi
}

env_cidr_contains_ip() {
    local cidr="$1" ip="$2" mask
    mask="$(env_cidr_mask "${cidr#*/}")"
    (( ($(env_ipv4_to_int "${ip}") & mask) == ($(env_ipv4_to_int "${cidr%/*}") & mask) ))
}

env_cidr_is_network_address() {
    local cidr="$1" base mask
    base="$(env_ipv4_to_int "${cidr%/*}")"
    mask="$(env_cidr_mask "${cidr#*/}")"
    (( (base & mask) == base ))
}

env_cidr_broadcast_int() {
    local cidr="$1" base prefix
    base="$(env_ipv4_to_int "${cidr%/*}")"
    prefix="${cidr#*/}"
    printf '%s\n' $(( (base & $(env_cidr_mask "${prefix}")) | ((1 << (32 - prefix)) - 1) ))
}

env_cidr_overlaps() {
    local a="$1" b="$2"
    env_cidr_contains_ip "${a}" "${b%/*}" && return 0
    env_cidr_contains_ip "${b}" "${a%/*}" && return 0
    return 1
}

# RFC 1918 and the RFC 6598 shared range.
env_ip_private() {
    local ip="$1" range
    for range in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10; do
        env_cidr_contains_ip "${range}" "${ip}" && return 0
    done
    return 1
}
