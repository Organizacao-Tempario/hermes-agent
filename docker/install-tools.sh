#!/bin/sh
# Build-time installer for the agent toolbox (runs as root in the Dockerfile).
#
# Debian packages come from the base image's signed apt repos. Release
# binaries are pinned (versions below, bumped by Renovate - see renovate.json)
# and SHA-256 verified against the upstream checksum file. The railway CLI
# publishes no checksum file; it is fetched over HTTPS from the pinned GitHub
# release only.
#
# Usage: install-tools.sh [PREFIX]   (default /usr/local/bin; PREFIX lets the
# release part be exercised without root: SKIP_APT=1 install-tools.sh /tmp/x)
set -eu

prefix="${1:-/usr/local/bin}"

# renovate: datasource=github-releases depName=mikefarah/yq
YQ_VERSION="${YQ_VERSION:-v4.54.3}"
# renovate: datasource=github-releases depName=hadolint/hadolint
HADOLINT_VERSION="${HADOLINT_VERSION:-v2.15.1}"
# renovate: datasource=github-releases depName=gitleaks/gitleaks
GITLEAKS_VERSION="${GITLEAKS_VERSION:-v8.30.1}"
# renovate: datasource=github-releases depName=aquasecurity/trivy
TRIVY_VERSION="${TRIVY_VERSION:-v0.76.2}"
# renovate: datasource=github-releases depName=astral-sh/uv
UV_VERSION="${UV_VERSION:-0.13.10}"
# renovate: datasource=github-releases depName=railwayapp/cli
RAILWAY_VERSION="${RAILWAY_VERSION:-v5.76.2}"

case "$(uname -m)" in
    x86_64|amd64)  a_go=amd64; a_gnu=x86_64; a_gl=x64;   a_tv=64bit; a_hl=x86_64 ;;
    aarch64|arm64) a_go=arm64; a_gnu=aarch64; a_gl=arm64; a_tv=ARM64; a_hl=arm64 ;;
    *) echo "unsupported arch $(uname -m)" >&2; exit 1 ;;
esac

if [ "${SKIP_APT:-0}" != 1 ]; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        jq shellcheck postgresql-client redis-tools sqlite3
    rm -rf /var/lib/apt/lists/*
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
gh_dl() { curl -fsSL --retry 3 -o "$tmp/$2" "https://github.com/$1/releases/download/$3/$2"; }
verify() { # verify <file> <sha256>
    [ -n "$2" ] || { echo "no checksum for $1" >&2; exit 1; }
    echo "$2  $tmp/$1" | sha256sum -c -
}

# yq: `checksums` lists 31 hashes per file; SHA-256 is the 18th (field 19).
f="yq_linux_$a_go"
gh_dl mikefarah/yq "$f" "$YQ_VERSION"; gh_dl mikefarah/yq checksums "$YQ_VERSION"
verify "$f" "$(awk -v f="$f" '$1 == f {print $19}' "$tmp/checksums")"
install -m 0755 "$tmp/$f" "$prefix/yq"

f="hadolint-linux-$a_hl"
gh_dl hadolint/hadolint "$f" "$HADOLINT_VERSION"; gh_dl hadolint/hadolint checksums.sha256 "$HADOLINT_VERSION"
verify "$f" "$(awk -v f="*$f" '$2 == f {print $1}' "$tmp/checksums.sha256")"
install -m 0755 "$tmp/$f" "$prefix/hadolint"

v="${GITLEAKS_VERSION#v}"; f="gitleaks_${v}_linux_$a_gl.tar.gz"; c="gitleaks_${v}_checksums.txt"
gh_dl gitleaks/gitleaks "$f" "$GITLEAKS_VERSION"; gh_dl gitleaks/gitleaks "$c" "$GITLEAKS_VERSION"
verify "$f" "$(awk -v f="$f" '$2 == f {print $1}' "$tmp/$c")"
tar -xzf "$tmp/$f" -C "$tmp" gitleaks && install -m 0755 "$tmp/gitleaks" "$prefix/gitleaks"

v="${TRIVY_VERSION#v}"; f="trivy_${v}_Linux-$a_tv.tar.gz"; c="trivy_${v}_checksums.txt"
gh_dl aquasecurity/trivy "$f" "$TRIVY_VERSION"; gh_dl aquasecurity/trivy "$c" "$TRIVY_VERSION"
verify "$f" "$(awk -v f="$f" '$2 == f {print $1}' "$tmp/$c")"
tar -xzf "$tmp/$f" -C "$tmp" trivy && install -m 0755 "$tmp/trivy" "$prefix/trivy"

f="uv-$a_gnu-unknown-linux-gnu.tar.gz"
gh_dl astral-sh/uv "$f" "$UV_VERSION"; gh_dl astral-sh/uv sha256.sum "$UV_VERSION"
verify "$f" "$(awk -v f="*$f" '$2 == f || $2 == substr(f, 2) {print $1}' "$tmp/sha256.sum")"
tar -xzf "$tmp/$f" -C "$tmp"
install -m 0755 "$tmp/uv-$a_gnu-unknown-linux-gnu/uv" "$tmp/uv-$a_gnu-unknown-linux-gnu/uvx" "$prefix/"

f="railway-$RAILWAY_VERSION-$a_gnu-unknown-linux-musl.tar.gz"
gh_dl railwayapp/cli "$f" "$RAILWAY_VERSION"
tar -xzf "$tmp/$f" -C "$tmp" railway && install -m 0755 "$tmp/railway" "$prefix/railway"

for t in yq hadolint gitleaks trivy uv railway; do
    printf '%s: ' "$t"; "$prefix/$t" --version 2>&1 | head -n1
done
