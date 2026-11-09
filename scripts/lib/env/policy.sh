#!/usr/bin/env bash
# Ownership of every runtime variable.
#   framework  value always comes from .env.example
#   user       an existing value is kept; the example only provides a default
#   generated  an existing real value is kept; otherwise update-env.sh creates one
# Every key in .env.example must be listed here and vice versa (test.sh checks).

declare -gA ENV_POLICY=(
    [TZ]=user
    [COMPOSE_PROJECT_NAME]=framework
    [DATA_DIR]=framework
    [BACKUP_LOCAL_DIR]=framework
    [SJV_DOMAIN]=framework
    [MQTT_HOSTNAME]=user

    [DOCKER_PROXY_SUBNET]=user
    [DOCKER_PROXY_GATEWAY]=user
    [DOCKER_INTERNAL_SUBNET]=user
    [DOCKER_INTERNAL_GATEWAY]=user
    [DOCKER_MQTT_SUBNET]=user
    [DOCKER_MQTT_GATEWAY]=user
    [DOCKER_EGRESS_SUBNET]=user
    [DOCKER_EGRESS_GATEWAY]=user

    [PROXY_PROTOCOL_MODE]=user
    [PROXY_PROTOCOL_TRUSTED_IPS]=user
    [TRAEFIK_TLS_MODE]=user
    [TRAEFIK_ACME_EMAIL]=user
    [TRAEFIK_ADMIN_PUBLISH]=user
    [ADMIN_IP_ALLOWLIST]=user
    [TRAEFIK_IMAGE]=framework
    [CROWDSEC_IMAGE]=framework
    [CROWDSEC_BOUNCER_PLUGIN]=framework
    [CROWDSEC_BOUNCER_PLUGIN_HASH]=framework

    [PG_DB]=framework
    [PG_BOOTSTRAP_USER]=framework
    [PG_BOOTSTRAP_PASSWORD]=generated
    [PG_OWNER_USER]=framework
    [PG_OWNER_PASSWORD]=generated
    [PG_API_USER]=framework
    [PG_API_PASSWORD]=generated
    [PG_COLLECTOR_USER]=framework
    [PG_COLLECTOR_PASSWORD]=generated
    [PG_WORKER_USER]=framework
    [PG_WORKER_PASSWORD]=generated
    [PG_MAINTENANCE_USER]=framework
    [PG_MAINTENANCE_PASSWORD]=generated
    [PG_READONLY_USER]=framework
    [PG_READONLY_PASSWORD]=generated

    [MQTT_ADMIN_USER]=framework
    [MQTT_ADMIN_PASSWORD]=generated
    [MQTT_COLLECTOR_USER]=framework
    [MQTT_COLLECTOR_PASSWORD]=generated
    [MQTT_HEALTHCHECK_USER]=framework
    [MQTT_HEALTHCHECK_PASSWORD]=generated

    [INGEST_MAX_MESSAGE_AGE_DAYS]=user
    [INGEST_KEY_RETENTION_DAYS]=framework

    [RESTIC_REPOSITORY]=user
    [RESTIC_REST_PASSWORD]=user

    [SMTP_HOST]=user
    [SMTP_PORT]=user
    [SMTP_SECURITY]=user
    [SMTP_USER]=user
    [SMTP_PASSWORD]=user
    [MAIL_FROM]=user

    [LOG_MAX_SIZE]=framework
    [LOG_MAX_FILES]=framework
)

# Keys that may stay empty. Everything else must have a value.
readonly ENV_OPTIONAL_KEYS=(
    PROXY_PROTOCOL_TRUSTED_IPS
    TRAEFIK_ADMIN_PUBLISH
    RESTIC_REPOSITORY
    RESTIC_REST_PASSWORD
    SMTP_HOST
    SMTP_USER
    SMTP_PASSWORD
    MAIL_FROM
)

# Placeholders that are accepted while the related feature is not enabled.
# The validator rejects them as soon as the feature needs the value.
readonly ENV_DEFERRED_PLACEHOLDER_KEYS=(
    TRAEFIK_ACME_EMAIL
)

# Read by sync.sh and validate.sh after they source this file.
# shellcheck disable=SC2034
readonly ENV_GENERATED_SECRET_BYTES=36 ENV_MIN_GENERATED_LENGTH=32 ENV_MIN_USER_SECRET_LENGTH=16

env_policy_of() {
    printf '%s\n' "${ENV_POLICY[$1]:-}"
}

env_is_placeholder() { [[ "$1" == set_* ]]; }

env_is_sensitive() {
    [[ "$1" == *PASSWORD* || "$1" == *SECRET* || "$1" == *TOKEN* || "$1" == *_KEY ]]
}

env_is_optional() {
    local key="$1" item
    for item in "${ENV_OPTIONAL_KEYS[@]}"; do
        [[ "${item}" == "${key}" ]] && return 0
    done
    return 1
}

env_is_deferred_placeholder() {
    local key="$1" item
    for item in "${ENV_DEFERRED_PLACEHOLDER_KEYS[@]}"; do
        [[ "${item}" == "${key}" ]] && return 0
    done
    return 1
}

# Value suitable for messages: secrets are never shown.
env_display_value() {
    local key="$1" value="$2"
    if env_is_sensitive "${key}"; then
        printf '%s\n' "<hidden>"
    elif [[ -z "${value}" ]]; then
        printf '%s\n' "<empty>"
    else
        printf '%s\n' "${value}"
    fi
}
