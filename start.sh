#!/bin/bash
set -e

# The dashboard is NOT started here. Since the s6-overlay switch the image
# ships its own supervised dashboard service (docker/s6-rc.d/dashboard),
# gated on HERMES_DASHBOARD and bound via HERMES_DASHBOARD_HOST/_PORT.
# Running it from CMD as well would just fight it for the port.
#
# Note it needs an auth provider: since the June 2026 hardening the gate
# engages on every non-loopback bind and --insecure / HERMES_DASHBOARD_INSECURE
# are accepted but ignored. Set HERMES_DASHBOARD_BASIC_AUTH_USERNAME plus
# _PASSWORD (bundled dashboard_auth/basic plugin) or the dashboard fails closed
# and takes the container down with it.

# Plugins live on the /opt/data volume, not in the image, so they cannot be
# updated at build time. Bring them up to date on every boot, BEFORE the
# gateway starts, so a fresh deploy never runs stale plugins until the
# gateway's own 24h auto-update (plugins.auto_apply) fires. This also re-runs
# the shared-venv sync and writes a receipt to
# /opt/data/logs/update_receipts/ (check with `hermes pm status`).
# Never fatal: a failing update (network, caution-verdict scan, uv error)
# must not keep the agent down. Opt out with HERMES_PLUGINS_UPDATE_ON_BOOT=0.
if [ "${HERMES_PLUGINS_UPDATE_ON_BOOT:-1}" != "0" ]; then
    echo "[start] plugins: checking for updates"
    timeout "${HERMES_PLUGINS_UPDATE_TIMEOUT:-300}" hermes plugins check-updates \
        || echo "[start] plugins: check-updates failed (exit $?), continuing"
    # --yes is required without a terminal. No --force: a plugin whose
    # security scan returns a caution verdict is skipped, not installed.
    timeout "${HERMES_PLUGINS_UPDATE_TIMEOUT:-300}" hermes plugins update --yes \
        || echo "[start] plugins: update failed (exit $?), continuing with installed versions"
fi

# Establish the default gateway profile's durable "running" intent. This only
# does real work on the first boot of a fresh volume: cont-init's profile
# reconciler auto-starts profiles whose last desired_state was "running", but a
# never-started profile is only registered, so without this the gateway would
# stay down forever. Returns immediately - the gateway runs under s6.
hermes gateway run

# CMD is /init's main program: when it exits the whole supervision tree comes
# down. Nothing left to do in the foreground, so just stay alive.
exec sleep infinity
