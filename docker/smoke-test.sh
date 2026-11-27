#!/bin/sh
# Boot the built image the way Railway does (fresh volume, no Multica login)
# and assert the container comes up healthy. Usage: smoke-test.sh <image>
set -eu
image="$1"
name="hermes-smoke-$$"
fail() { echo "SMOKE FAIL: $*" >&2; docker logs "$name" 2>&1 | tail -n 100 >&2; exit 1; }
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; docker volume rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker volume create "$name" >/dev/null
docker run -d --name "$name" -v "$name:/opt/data" "$image" >/dev/null

# 1. The service script installs multica + claude (latest) on the volume,
#    then parks itself because there is no login (marker + finish 125).
i=0
until docker exec "$name" test -e /run/multica-daemon.down 2>/dev/null; do
    i=$((i + 1)); [ "$i" -le 60 ] || fail "multica-daemon never reached the parked state"
    [ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ] || fail "container exited"
    sleep 5
done
docker logs "$name" 2>&1 | grep -q 'not logged in' || fail "expected 'not logged in' message"

# 2. Container stays up (CMD + s6 tree healthy) after the service settled.
sleep 15
[ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ] || fail "container exited after boot"

# 2b. start.sh ran the boot-time plugin update step (empty volume: a no-op).
docker logs "$name" 2>&1 | grep -q '\[start\] plugins: checking for updates' || fail "boot plugin update step did not run"

# 3. Agent CLIs on the volume, owned by hermes; toolbox on PATH.
docker exec -u hermes -e HOME=/opt/data "$name" /opt/data/.local/bin/multica version || fail "multica missing"
docker exec -u hermes -e HOME=/opt/data "$name" /opt/data/.local/bin/claude --version || fail "claude missing"
for t in /opt/hermes-railway/bin/gh jq yq shellcheck hadolint gitleaks trivy uv railway psql redis-cli sqlite3; do
    docker exec "$name" sh -c "command -v $t >/dev/null" || fail "$t missing"
done
[ "$(docker exec "$name" stat -c %U /opt/data/.local/bin/multica)" = hermes ] || fail "multica not owned by hermes"

# 4. The s6 slot exists and is down (not crash-looping). s6 tools live in
#    /command, which is not on the docker exec PATH.
docker exec "$name" /command/s6-svstat /run/service/multica-daemon || fail "no s6 slot"
docker exec "$name" /command/s6-svstat /run/service/multica-daemon | grep -q '^down' || fail "slot should be down without a login"

echo "SMOKE OK"
