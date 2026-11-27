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

# --- GitHub CLI -----------------------------------------------------------
# Pinned + checksum-verified. Auth state lives on the volume
# (/opt/data/.config/gh), so `gh auth login` as hermes survives redeploys.
ARG GH_VERSION=2.106.0
RUN set -eu; \
    arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    base="https://github.com/cli/cli/releases/download/v${GH_VERSION}"; \
    pkg="gh_${GH_VERSION}_linux_${arch}.tar.gz"; \
    tmp="$(mktemp -d)"; \
    curl -fsSL -o "$tmp/$pkg" "$base/$pkg"; \
    curl -fsSL -o "$tmp/checksums.txt" "$base/gh_${GH_VERSION}_checksums.txt"; \
    (cd "$tmp" && grep " ${pkg}\$" checksums.txt | sha256sum -c -); \
    tar -xzf "$tmp/$pkg" -C "$tmp"; \
    install -m 0755 -o root -g root "$tmp/gh_${GH_VERSION}_linux_${arch}/bin/gh" /usr/local/bin/gh; \
    rm -rf "$tmp"; \
    /usr/local/bin/gh --version

# --- Claude Code CLI -------------------------------------------------------
# Native binary, pinned and verified against the release manifest. Agent
# runs launched by the daemon use this copy (/usr/local/bin precedes the
# volume's ~/.local/bin); its auto-updater is disabled in the daemon env, so
# upgrade by bumping CLAUDE_VERSION. Auth/config stay on the volume
# (/opt/data/.claude, /opt/data/.claude.json).
ARG CLAUDE_VERSION=2.1.331
RUN set -eu; \
    arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "$arch" in amd64) plat=linux-x64 ;; arm64) plat=linux-arm64 ;; *) echo "unsupported arch: $arch" >&2; exit 1 ;; esac; \
    base="https://downloads.claude.ai/claude-code-releases/${CLAUDE_VERSION}"; \
    tmp="$(mktemp -d)"; \
    curl -fsSL -o "$tmp/manifest.json" "$base/manifest.json"; \
    curl -fsSL -o "$tmp/claude" "$base/$plat/claude"; \
    sum="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["platforms"][sys.argv[2]]["checksum"])' "$tmp/manifest.json" "$plat")"; \
    echo "$sum  $tmp/claude" | sha256sum -c -; \
    install -m 0755 -o root -g root "$tmp/claude" /usr/local/bin/claude; \
    rm -rf "$tmp"; \
    /usr/local/bin/claude --version

COPY s6-rc.d/multica-daemon /etc/s6-overlay/s6-rc.d/multica-daemon
RUN chmod 0755 /etc/s6-overlay/s6-rc.d/multica-daemon/run \
               /etc/s6-overlay/s6-rc.d/multica-daemon/finish \
 && touch /etc/s6-overlay/s6-rc.d/user/contents.d/multica-daemon

# --- Railway entrypoint ---------------------------------------------------
COPY start.sh /opt/hermes/railway-start.sh
RUN chmod +x /opt/hermes/railway-start.sh

CMD ["/opt/hermes/railway-start.sh"]
