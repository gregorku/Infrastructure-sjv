#!/usr/bin/env bash
# Renders Traefik's static and dynamic files into the stack runtime directory.
# The Git checkout is only read. Generated files contain no bouncer key.

# Filled by deploy_render_runtime and read by the writers below.
# shellcheck disable=SC2034
declare -ga RENDER_ALLOW_ITEMS=() RENDER_TRUSTED_ITEMS=()

render_quote() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Writes stdin to a file, replacing it only when the bytes differ.
render_write() {
    local dst="$1" mode="$2" tmp=""
    [[ "${dst}" == "${STACK_DIR}/"* && "${dst}" != *..* ]] || fail "Refusing to render outside the stack directory."
    [[ ! -e "${dst}" || ! -L "${dst}" ]] || fail "${dst} is a symlink. Refusing to replace it."
    tmp="$(mktemp "${dst}.tmp.XXXXXX")"
    if ! cat > "${tmp}"; then
        rm -f -- "${tmp}"
        return 1
    fi
    chmod "${mode}" "${tmp}"
    if [[ -f "${dst}" ]] && cmp -s "${tmp}" "${dst}"; then
        rm -f -- "${tmp}"
        return 0
    fi
    if ! mv -f -- "${tmp}" "${dst}"; then
        rm -f -- "${tmp}"
        return 1
    fi
    chmod "${mode}" "${dst}"
}

render_bouncer_ready() {
    local state
    [[ -e "${BOUNCER_KEY_FILE}" || -L "${BOUNCER_KEY_FILE}" ]] || return 1
    [[ -f "${BOUNCER_KEY_FILE}" && ! -L "${BOUNCER_KEY_FILE}" ]] \
        || fail "Bouncer key path is not a regular file. Traefik was not reconfigured."
    [[ "$(file_mode "${BOUNCER_KEY_FILE}")" == 600 ]] \
        || fail "Bouncer key file must be mode 600 before Traefik can use it."
    state="$(post_deploy_key_file_state "${BOUNCER_KEY_FILE}")"
    [[ "${state}" == valid ]] || fail "Bouncer key file is ${state}. Traefik was not reconfigured."
}

render_copy_static() {
    local dynamic="$1" name src dst
    for name in tls.yml headers.yml; do
        src="${GIT_DIR}/configs/traefik/dynamic/${name}"
        dst="${dynamic}/${name}"
        [[ -f "${src}" && ! -L "${src}" ]] || fail "Missing Traefik file: ${src}"
        if [[ -f "${dst}" ]] && cmp -s "${src}" "${dst}"; then
            continue
        fi
        install -m 644 "${src}" "${dst}"
    done
}

render_ip_allowlist() {
    local dynamic="$1" item
    {
        printf '%s\n' 'http:' '  middlewares:' '    ip-allowlist:' '      ipAllowList:' '        sourceRange:'
        for item in "${RENDER_ALLOW_ITEMS[@]}"; do
            printf '          - "%s"\n' "$(render_quote "${item}")"
        done
    } | render_write "${dynamic}/ip-allowlist.yml" 644
}

render_chains() {
    local dynamic="$1" crowdsec="$2"
    {
        printf '%s\n' 'http:' '  middlewares:'
        printf '%s\n' '    rate-limit:' '      rateLimit:' '        average: 100' '        burst: 200'
        printf '%s\n' '    compress:' '      compress: {}'
        printf '%s\n' '    app-chain:' '      chain:' '        middlewares:'
        [[ "${crowdsec}" == yes ]] && printf '%s\n' '          - crowdsec'
        printf '%s\n' '          - headers-security' '          - rate-limit' '          - compress'
        if [[ -f "${HTPASSWD_FILE}" && ! -L "${HTPASSWD_FILE}" ]]; then
            printf '%s\n' '    auth-basic:' '      basicAuth:' \
                '        realm: "Infrastructure-sjv"' \
                '        usersFile: "/etc/traefik/users/dashboard.htpasswd"'
            printf '%s\n' '    dashboard-chain:' '      chain:' '        middlewares:'
            [[ "${crowdsec}" == yes ]] && printf '%s\n' '          - crowdsec'
            printf '%s\n' '          - ip-allowlist' '          - headers-security' '          - auth-basic'
        fi
    } | render_write "${dynamic}/chains.yml" 644
}

render_crowdsec_middleware() {
    local dynamic="$1"
    cat <<EOF | render_write "${dynamic}/crowdsec.yml" 644
http:
  middlewares:
    crowdsec:
      plugin:
        crowdsec:
          enabled: true
          crowdsecMode: live
          crowdsecLapiScheme: http
          crowdsecLapiHost: crowdsec:8080
          crowdsecLapiKeyFile: /etc/traefik/crowdsec/BOUNCER_KEY_${CROWDSEC_BOUNCER_NAME}
EOF
}

render_dashboard() {
    local dynamic="$1"
    cat <<'EOF' | render_write "${dynamic}/dashboard.yml" 644
http:
  routers:
    traefik-dashboard:
      entryPoints:
        - admin
      rule: PathPrefix(`/api`) || PathPrefix(`/dashboard`)
      service: api@internal
      middlewares:
        - dashboard-chain
      tls:
        options: default
      priority: 100
EOF
}

render_app() {
    local dynamic="$1" domain="$2" tls_mode="$3" tls_line
    if [[ "${tls_mode}" == letsencrypt ]]; then
        tls_line="        certResolver: letsencrypt"
    else
        tls_line="        options: default"
    fi
    cat <<EOF | render_write "${dynamic}/app.yml" 644
http:
  routers:
    sjv-api:
      entryPoints:
        - websecure
      rule: "Host(\`${domain}\`) && PathPrefix(\`/api\`)"
      priority: 100
      service: sjv-backend
      middlewares:
        - app-chain
      tls:
${tls_line}
    sjv-web:
      entryPoints:
        - websecure
      rule: "Host(\`${domain}\`)"
      priority: 1
      service: sjv-web
      middlewares:
        - app-chain
      tls:
${tls_line}
  services:
    sjv-backend:
      loadBalancer:
        passHostHeader: true
        servers:
          - url: ${APP_BACKEND_URL}
    sjv-web:
      loadBalancer:
        passHostHeader: true
        servers:
          - url: ${APP_WEB_URL}
EOF
}

render_mqtt_certificate() {
    local dynamic="$1" host="$2"
    cat <<EOF | render_write "${dynamic}/mqtt-cert.yml" 644
http:
  routers:
    sjv-mqtt-certificate:
      entryPoints:
        - websecure
      rule: "Host(\`${host}\`)"
      service: noop@internal
      tls:
        certResolver: letsencrypt
      priority: 1
EOF
}

render_static_traefik() {
    local dst="$1" proxy_web="" proxy_secure="" acme="" src plugin
    plugin="${RUNTIME_ENV[CROWDSEC_BOUNCER_PLUGIN]}"
    if [[ "${RUNTIME_ENV[PROXY_PROTOCOL_MODE]}" == haproxy ]]; then
        proxy_web=$'    proxyProtocol:\n      trustedIPs:\n'
        proxy_secure=$'    proxyProtocol:\n      trustedIPs:\n'
        for src in "${RENDER_TRUSTED_ITEMS[@]}"; do
            proxy_web+="        - \"$(render_quote "${src}")\""$'\n'
            proxy_secure+="        - \"$(render_quote "${src}")\""$'\n'
        done
    fi
    if [[ "${RUNTIME_ENV[TRAEFIK_TLS_MODE]}" == letsencrypt ]]; then
        acme="$(cat <<EOF
certificatesResolvers:
  letsencrypt:
    acme:
      email: "$(render_quote "${RUNTIME_ENV[TRAEFIK_ACME_EMAIL]}")"
      storage: /etc/traefik/acme/acme.json
      httpChallenge:
        entryPoint: web
EOF
)"
    fi
    cat <<EOF | render_write "${dst}" 644
global:
  checkNewVersion: false
  sendAnonymousUsage: false
api:
  dashboard: true
  insecure: false
ping:
  entryPoint: ping
entryPoints:
  ping:
    address: "127.0.0.1:8082"
  web:
    address: ":80"
${proxy_web}    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
          permanent: true
  websecure:
    address: ":443"
${proxy_secure}  admin:
    address: ":${TRAEFIK_ADMIN_PORT}"
providers:
  file:
    directory: /etc/traefik/dynamic
    watch: true
experimental:
  plugins:
    crowdsec:
      moduleName: github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin
      version: ${plugin}
log:
  level: INFO
  filePath: /var/log/traefik/traefik.log
accessLog:
  filePath: /var/log/traefik/access.log
${acme}
EOF
}

render_admin_port() {
    local publish="$1" dst="${STACK_DIR}/compose/15-traefik-admin-port.yml" git_file
    git_file="${GIT_DIR}/compose/15-traefik-admin-port.yml"
    if [[ -z "${publish}" ]]; then
    if [[ -f "${git_file}" ]] && cmp -s "${git_file}" "${dst}"; then
        return 0
    fi
    install -m 644 "${git_file}" "${dst}"
    return 0
    fi
    [[ -f "${HTPASSWD_FILE}" && ! -L "${HTPASSWD_FILE}" ]] \
        || fail "TRAEFIK_ADMIN_PUBLISH is set, but the dashboard password file is missing. Run ./scripts/create-dashboard-user.sh. Nothing was published."
    cat <<EOF | render_write "${dst}" 644
services:
  traefik:
    ports:
      - "${publish}"
EOF
}

render_check_result() {
    local file="$1"
    [[ -f "${file}" && ! -L "${file}" ]] || fail "Rendered file is missing: ${file}"
    if grep -q 'docker.sock' "${file}"; then
        fail "Rendered Traefik refers to the Docker socket."
    fi
    if grep -q 'providers:' "${file}" && grep -q 'docker:' "${file}"; then
        fail "Rendered Traefik enables the Docker provider."
    fi
    if grep -q '0.0.0.0/0' "${file}"; then
        fail "Rendered Traefik trusts 0.0.0.0/0."
    fi
    if grep -q 'forwardedHeaders:' "${file}"; then
        fail "Rendered Traefik trusts forwarded headers."
    fi
    if grep -A2 'proxyProtocol:' "${file}" | grep -q 'insecure: true'; then
        fail "Rendered Traefik enables proxyProtocol.insecure."
    fi
}

deploy_render_runtime() {
    print_section "Render runtime files"
    local dynamic="${RUNTIME_DIR}/traefik/dynamic" crowdsec=no address
    RENDER_ALLOW_ITEMS=()
    RENDER_TRUSTED_ITEMS=()
    [[ ! -L "${RUNTIME_DIR}" && ! -L "${RUNTIME_DIR}/traefik" && ! -L "${dynamic}" ]] \
        || fail "Runtime Traefik path is a symlink. Refusing to render into it."
    install -d -m 755 "${dynamic}"
    address="$(env_address_after_gateway "${RUNTIME_ENV[DOCKER_PROXY_SUBNET]}" "${RUNTIME_ENV[DOCKER_PROXY_GATEWAY]}")" \
        || fail "Cannot place Traefik inside ${RUNTIME_ENV[DOCKER_PROXY_SUBNET]} behind its gateway."
    printf '%s\n' "${address}" | render_write "${RUNTIME_DIR}/traefik-proxy-address" 644

    env_words RENDER_ALLOW_ITEMS "${RUNTIME_ENV[ADMIN_IP_ALLOWLIST]}"
    (( ${#RENDER_ALLOW_ITEMS[@]} > 0 )) || fail "ADMIN_IP_ALLOWLIST produced no addresses."
    if [[ "${RUNTIME_ENV[PROXY_PROTOCOL_MODE]}" == haproxy ]]; then
        env_words RENDER_TRUSTED_ITEMS "${RUNTIME_ENV[PROXY_PROTOCOL_TRUSTED_IPS]}"
    fi

    if render_bouncer_ready; then
        crowdsec=yes
    else
        warn "CrowdSec bouncer is not attached yet. ./scripts/post-deploy.sh registers the key after CrowdSec is running."
        rm -f -- "${dynamic}/crowdsec.yml"
    fi

    render_copy_static "${dynamic}"
    render_ip_allowlist "${dynamic}"
    render_chains "${dynamic}" "${crowdsec}"
    [[ "${crowdsec}" == yes ]] && render_crowdsec_middleware "${dynamic}"
    render_app "${dynamic}" "${RUNTIME_ENV[SJV_DOMAIN]}" "${RUNTIME_ENV[TRAEFIK_TLS_MODE]}"
    if [[ "${RUNTIME_ENV[MQTT_HOSTNAME]}" == "sjv-mqtt.serveftp.org" && "${RUNTIME_ENV[TRAEFIK_TLS_MODE]}" == letsencrypt ]]; then
        render_mqtt_certificate "${dynamic}" "${RUNTIME_ENV[MQTT_HOSTNAME]}"
    else
        rm -f -- "${dynamic}/mqtt-cert.yml"
    fi
    if [[ -f "${HTPASSWD_FILE}" && ! -L "${HTPASSWD_FILE}" ]]; then
        render_dashboard "${dynamic}"
    else
        rm -f -- "${dynamic}/dashboard.yml"
        warn "Dashboard router is not installed until ./scripts/create-dashboard-user.sh has run."
    fi
    render_static_traefik "${RUNTIME_DIR}/traefik/traefik.yml"
    render_admin_port "${RUNTIME_ENV[TRAEFIK_ADMIN_PUBLISH]}"
    render_check_result "${RUNTIME_DIR}/traefik/traefik.yml"
    ok "Runtime configuration rendered. Traefik has no Docker socket."
}
