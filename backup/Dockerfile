# sjv-backup: pinned Restic plus a long-running scheduler.
# The published restic image is a one-shot binary and has no shell or scheduler.
# Checksums are the official v0.19.1 SHA256SUMS (linux_amd64 and linux_arm64).

FROM alpine:3.22

ARG RESTIC_VERSION=0.19.1
ARG TARGETARCH

# util-linux provides flock. The build rejects a BusyBox applet of the same name.
RUN apk add --no-cache bash ca-certificates bzip2 jq tzdata util-linux \
    && case "${TARGETARCH}" in \
        amd64) restic_arch=amd64; restic_sha=f415415624dcc452f2a02b8c33641791a8c6d6d3b65bbb3543fcf9a25151585c ;; \
        arm64) restic_arch=arm64; restic_sha=a5f64aaab53d51e311fa3829124c5b703f2d14cf187d8640b6be3b2b49376465 ;; \
        *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && wget -O "/tmp/restic.bz2" \
        "https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_${restic_arch}.bz2" \
    && echo "${restic_sha}  /tmp/restic.bz2" | sha256sum -c - \
    && bunzip2 /tmp/restic.bz2 \
    && install -m 0755 /tmp/restic /usr/local/bin/restic \
    && rm -f /tmp/restic \
    && flock --version | grep -q 'util-linux' \
    && restic version

COPY sjv-backup.sh /usr/local/bin/sjv-backup
RUN chmod 755 /usr/local/bin/sjv-backup

# Root is required: backup trees and the key file are mode 700/600 and owned
# by the host root. Capabilities are dropped in Compose.
USER 0

ENTRYPOINT ["/usr/local/bin/sjv-backup"]
CMD ["supervise"]
