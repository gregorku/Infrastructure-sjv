# sjv-postgresql: pinned PostgreSQL 19.0 plus pgBackRest 2.60.1.
# POSTGRES_IMAGE is the digest-pinned base from .env.example. There is no
# default, so a build cannot silently fall back to the floating tag 19 or latest.
# The official entrypoint and command stay in place. This image only adds the
# backup client, its configuration and the first-init role scripts.

ARG POSTGRES_IMAGE
FROM ${POSTGRES_IMAGE}

ARG PGBACKREST_VERSION=2.60.1
# SHA-256 of the official pgbackrest-2.60.1.tar.gz release tarball.
ARG PGBACKREST_SHA256=c6d8190fee982f0febdd2ca5ca112f83b4b0905ef9949e9cf64a46a6cc138026

USER root

RUN set -eux; \
    test "${PGBACKREST_VERSION}" = "2.60.1"; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates wget \
        meson ninja-build gcc pkg-config \
        libpq-dev libssl-dev libxml2-dev libcurl4-openssl-dev libyaml-dev \
        liblz4-dev libzstd-dev libbz2-dev zlib1g-dev; \
    wget -O /tmp/pgbackrest.tar.gz \
        "https://github.com/pgbackrest/pgbackrest/releases/download/release%2F${PGBACKREST_VERSION}/pgbackrest-${PGBACKREST_VERSION}.tar.gz"; \
    echo "${PGBACKREST_SHA256}  /tmp/pgbackrest.tar.gz" | sha256sum -c -; \
    mkdir -p /tmp/pgbackrest-src; \
    tar -xzf /tmp/pgbackrest.tar.gz -C /tmp/pgbackrest-src --strip-components=1; \
    meson setup /tmp/pgbackrest-build /tmp/pgbackrest-src; \
    ninja -C /tmp/pgbackrest-build; \
    install -m 0755 /tmp/pgbackrest-build/src/pgbackrest /usr/bin/pgbackrest; \
    rm -rf /tmp/pgbackrest.tar.gz /tmp/pgbackrest-src /tmp/pgbackrest-build; \
    apt-get purge -y --auto-remove \
        meson ninja-build gcc pkg-config \
        libpq-dev libssl-dev libxml2-dev libcurl4-openssl-dev libyaml-dev \
        liblz4-dev libzstd-dev libbz2-dev zlib1g-dev \
        wget; \
    apt-get install -y --no-install-recommends \
        libpq5 libssl3t64 libxml2 libcurl4t64 libyaml-0-2 \
        liblz4-1 libzstd1 libbz2-1.0 zlib1g; \
    rm -rf /var/lib/apt/lists/*; \
    pgbackrest version | grep -F "pgBackRest ${PGBACKREST_VERSION}"

COPY pgbackrest.conf /etc/pgbackrest/pgbackrest.conf
COPY docker-entrypoint-initdb.d/ /docker-entrypoint-initdb.d/

RUN set -eux; \
    chmod 644 /etc/pgbackrest/pgbackrest.conf; \
    chown root:postgres /etc/pgbackrest/pgbackrest.conf; \
    chmod 755 /docker-entrypoint-initdb.d/*.sh; \
    chmod 644 /docker-entrypoint-initdb.d/*.sql; \
    install -d -o postgres -g postgres -m 0750 /var/log/pgbackrest

USER postgres

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["postgres", "-c", "archive_mode=on", "-c", "archive_command=pgbackrest --stanza=sjv archive-push %p", "-c", "archive_timeout=60"]
