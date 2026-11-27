FROM nousresearch/hermes-agent:latest

# --- GitHub CLI -----------------------------------------------------------
# Pinned + checksum-verified. Auth state lives on the volume
# (/opt/data/.config/gh), so `gh auth login` as hermes survives redeploys.
# Installed to /opt/hermes-railway/bin, which the daemon puts first on PATH so
# it wins over the older gh symlink on the volume's ~/.local/bin.
ARG TARGETARCH
ARG GH_VERSION=2.106.0
RUN set -eu; \
    arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    base="https://github.com/cli/cli/releases/download/v${GH_VERSION}"; \
    pkg="gh_${GH_VERSION}_linux_${arch}.tar.gz"; \
    tmp="$(mktemp -d)"; \
    mkdir -p /opt/hermes-railway/bin; \
    curl -fsSL -o "$tmp/$pkg" "$base/$pkg"; \
    curl -fsSL -o "$tmp/checksums.txt" "$base/gh_${GH_VERSION}_checksums.txt"; \
    (cd "$tmp" && grep " ${pkg}\$" checksums.txt | sha256sum -c -); \
    tar -xzf "$tmp/$pkg" -C "$tmp"; \
    install -m 0755 -o root -g root "$tmp/gh_${GH_VERSION}_linux_${arch}/bin/gh" /opt/hermes-railway/bin/gh; \
    rm -rf "$tmp"; \
    /opt/hermes-railway/bin/gh --version

# --- Multica daemon + agent CLIs -----------------------------------------
# multica and claude are NOT baked in: on every start the multica-daemon s6
# service installs/upgrades both to their latest releases in the hermes
# user's ~/.local/bin on the /opt/data volume (bin/update-agent-clis), and
# both then self-update while running (see s6-rc.d/multica-daemon/run).
COPY bin/update-agent-clis /opt/hermes-railway/update-agent-clis
COPY s6-rc.d/multica-daemon /etc/s6-overlay/s6-rc.d/multica-daemon
RUN chmod 0755 /opt/hermes-railway/update-agent-clis \
               /etc/s6-overlay/s6-rc.d/multica-daemon/run \
               /etc/s6-overlay/s6-rc.d/multica-daemon/finish \
 && touch /etc/s6-overlay/s6-rc.d/user/contents.d/multica-daemon

# --- Railway entrypoint ---------------------------------------------------
COPY start.sh /opt/hermes/railway-start.sh
RUN chmod +x /opt/hermes/railway-start.sh

CMD ["/opt/hermes/railway-start.sh"]
