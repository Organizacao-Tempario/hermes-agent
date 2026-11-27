FROM nousresearch/hermes-agent:latest

# --- Multica daemon -------------------------------------------------------
# The CLI is baked into the image (pinned + checksum-verified) and supervised
# by s6 as the unprivileged `hermes` user (see s6-rc.d/multica-daemon).
# Upgrade by bumping MULTICA_VERSION and redeploying: in-place auto-update is
# disabled because its spawn-and-exit handoff would race s6's restart.
ARG MULTICA_VERSION=0.13.0
ARG TARGETARCH
RUN set -eu; \
    arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "$arch" in amd64|arm64) ;; *) echo "unsupported arch: $arch" >&2; exit 1 ;; esac; \
    base="https://github.com/multica-ai/multica/releases/download/v${MULTICA_VERSION}"; \
    pkg="multica-cli-${MULTICA_VERSION}-linux-${arch}.tar.gz"; \
    tmp="$(mktemp -d)"; \
    curl -fsSL -o "$tmp/$pkg" "$base/$pkg"; \
    curl -fsSL -o "$tmp/checksums.txt" "$base/checksums.txt"; \
    (cd "$tmp" && grep " ${pkg}\$" checksums.txt | sha256sum -c -); \
    tar -xzf "$tmp/$pkg" -C "$tmp" multica; \
    install -m 0755 -o root -g root "$tmp/multica" /usr/local/bin/multica; \
    rm -rf "$tmp"; \
    /usr/local/bin/multica version

COPY s6-rc.d/multica-daemon /etc/s6-overlay/s6-rc.d/multica-daemon
RUN chmod 0755 /etc/s6-overlay/s6-rc.d/multica-daemon/run \
               /etc/s6-overlay/s6-rc.d/multica-daemon/finish \
 && touch /etc/s6-overlay/s6-rc.d/user/contents.d/multica-daemon

# --- Railway entrypoint ---------------------------------------------------
COPY start.sh /opt/hermes/railway-start.sh
RUN chmod +x /opt/hermes/railway-start.sh

CMD ["/opt/hermes/railway-start.sh"]
