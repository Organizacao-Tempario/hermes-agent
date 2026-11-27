---
name: hermes-agent-railway-deploy
description: Deploy, configure, verify and roll back the Tempario Hermes Agent service on Railway (repo Organizacao-Tempario/hermes-agent), including the s6-supervised Multica daemon that runs as the hermes user. Use for any release, config change, health check or incident on the Hermes Railway container.
---

# Hermes Agent on Railway

Repo: `https://github.com/Organizacao-Tempario/hermes-agent`. It is a thin
wrapper over the upstream image `nousresearch/hermes-agent:latest`.

| File | Role |
| --- | --- |
| `Dockerfile` | `FROM nousresearch/hermes-agent:latest`, installs the pinned Multica CLI (`MULTICA_VERSION`) and GitHub CLI (`GH_VERSION`) and Claude Code CLI (`CLAUDE_VERSION`) into `/usr/local/bin`, registers the `multica-daemon` s6 service, and sets `CMD` to `start.sh` |
| `start.sh` | Runs `hermes gateway run` once (sets the gateway's durable "running" state on a fresh volume), then `exec sleep infinity` |
| `s6-rc.d/multica-daemon/{run,finish,type,dependencies.d/base}` | Supervised Multica daemon running as `hermes` |
| `railway.toml` | Dockerfile builder, `restartPolicyType = "always"` |
| `TEMPLATE_DESCRIPTION.md` | Public Railway template copy (marketing text, not config) |

## Runtime model (what the upstream image does)

- PID 1 is s6-overlay's `/init` (root). `CMD` runs as `/init`'s main program:
  if `start.sh` exits, the whole container stops. Keep it ending in `exec sleep infinity`.
- s6 services live in `/etc/s6-overlay/s6-rc.d/`. The `user` bundle lists
  `main-hermes` (a no-op), `dashboard`, `profile-gateways`, and our
  `multica-daemon`. Live service dirs are under `/run/service/<name>`.
- Gateways run under a nested s6-svscan as `hermes` (`/run/hermes-service`).
  Do not start the gateway or dashboard from `CMD` too, or the two copies fight over the port.
- Persistent volume: `/opt/data` (`HERMES_HOME`, and `HOME` for `hermes`,
  uid/gid 10000). Everything that must survive a redeploy lives there:
  `config.yaml`, `.env`, skills, sessions, and `/opt/data/.multica`.
- Dashboard: enabled by `HERMES_DASHBOARD=1`, bound via `HERMES_DASHBOARD_HOST`/`_PORT`.
  On any non-loopback bind it needs an auth provider:
  `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` + `_PASSWORD`, or
  `HERMES_DASHBOARD_OAUTH_CLIENT_ID`. `HERMES_DASHBOARD_INSECURE` is ignored.
  If no provider is set, the dashboard refuses to start and takes the container down with it.

## Multica daemon (s6 service `multica-daemon`)

- Binary: `/usr/local/bin/multica`, pinned by `ARG MULTICA_VERSION` in the
  Dockerfile and checked against the release `checksums.txt`.
  **Upgrade = bump `MULTICA_VERSION` and redeploy.** The service runs the daemon with
  `--no-auto-update --no-auto-reload`. When the daemon updates itself outside
  systemd, it spawns a detached successor and exits 0, so s6 would start a
  second daemon. Do not turn these back on.
- Runs as `hermes` with `HOME=/opt/data` and a clean environment (`env -i`).
  Railway secrets such as the dashboard password are **not** passed to agent runs.
  `/opt/data/.profile` is sourced, so operator exports (for example `RAILWAY_TOKEN`)
  still reach agent runs.
- Login state: `/opt/data/.multica/config.json` on the volume, so it survives redeploys.
- Railway variables:
  - `MULTICA_DAEMON`: set `0`/`false` to disable (default: on).
  - `MULTICA_BOOTSTRAP_TOKEN`: a `mul_…` PAT, used **only** when the volume has no
    login yet. It is piped to `multica login --token` on stdin and is never passed to the daemon.
    Remove it from Railway after the first successful boot.
  - `MULTICA_SERVER_URL` (required for that first login), `MULTICA_APP_URL` (optional).
  - Optional overrides: `MULTICA_DAEMON_DEVICE_NAME`, `MULTICA_AGENT_RUNTIME_NAME`,
    `MULTICA_DAEMON_MAX_CONCURRENT_TASKS`. These win over `.profile`.
  - Do **not** set `MULTICA_TOKEN` as a container variable. The CLI treats it as an
    auth override, and inside agent runs it must be the task-scoped token.
- If the service is disabled or the volume has no login, `run` writes
  `/run/multica-daemon.down` and `finish` exits 125, so the slot stays down and
  does not restart in a loop. To recover by hand, run
  `su -s /bin/sh hermes -c 'HOME=/opt/data /usr/local/bin/multica login'` and then
  `s6-svc -u /run/service/multica-daemon`.
- Never start a second daemon by hand (`multica daemon start`) inside the
  container. It competes with the supervised one for `daemon.lock`.
  Never kill `multica` processes by name. Check `multica daemon status --output json` for the PID first.

## GitHub CLI (`gh`)

- `/usr/local/bin/gh` is pinned by `ARG GH_VERSION` and checksum-verified. To upgrade, bump the version and redeploy.
- In the daemon's PATH, `/usr/local/bin` comes before `/opt/data/.local/bin`, so the image's `gh` and `multica`
  win over older copies left on the volume.
- Auth lives on the volume (`/opt/data/.config/gh`). Set it up once as hermes with
  `su -s /bin/sh hermes -c 'HOME=/opt/data gh auth login'`, or export `GH_TOKEN` in `/opt/data/.profile`.
  Railway variables do **not** reach agent runs because the daemon starts with `env -i`.
- To verify: `su -s /bin/sh hermes -c 'HOME=/opt/data gh auth status'`.

## Claude Code CLI (`claude`)

- `/usr/local/bin/claude` is the native binary, pinned by `ARG CLAUDE_VERSION` and verified against the release
  `manifest.json` SHA-256. The daemon finds it first on PATH. That makes it the `claude` agent runtime.
- The daemon env sets `DISABLE_AUTOUPDATER=1`, so the binary doesn't write a second, self-updated copy to the volume.
  To upgrade, bump `CLAUDE_VERSION` and redeploy.
- Auth and config live on the volume (`/opt/data/.claude`, `/opt/data/.claude.json`) and survive redeploys.
  The older volume copy (`/opt/data/.local/bin/claude`) is now shadowed and can be removed later.
- To verify: `su -s /bin/sh hermes -c 'HOME=/opt/data claude --version'`. The daemon status should list `claude` under `agents`.

## Release checklist

1. **Scope**: commit/PR, target Railway environment, and whether the upstream
   `latest` tag moved. `latest` is unpinned, so a rebuild can pull a new Hermes.
   Record its digest with
   `docker buildx imagetools inspect nousresearch/hermes-agent:latest` (or the
   registry API) so you can roll back to it.
2. **Build**: Railway builds the Dockerfile. Locally, run `docker build .` and check that
   the `multica version`, `gh --version` and `claude --version` lines print during the build.
3. **Config** (compare variable *names* only, never print values): `PORT`,
   `HERMES_DASHBOARD*`, `MULTICA_*`. Remember the committed `.evn` file is not
   loaded by Railway. Real values belong in Railway variables.
4. **Migrations**: none in this repo. Hermes migrates its own state on the volume.
   Snapshot or back up the `/opt/data` volume before upgrading upstream across releases.
5. **Deploy**: non-production environments are free to deploy. **Production needs explicit human
   approval in the issue or conversation for each deploy.** Use `railway up` or a push to
   the linked branch. Use the `railway-environment-operations` skill for CLI specifics.
6. **Post-deploy health** (collect evidence, do not assume it):
   - Railway deploy status is `SUCCESS` and the container does not restart in a loop (check logs).
   - Logs show `[multica-daemon] starting multica <version> as hermes`.
   - In the container: `s6-svstat /run/service/multica-daemon`, which should be up with a growing uptime.
   - `su -s /bin/sh hermes -c 'HOME=/opt/data /usr/local/bin/multica daemon status --output json'`
     should show `status: running`, the expected `cli_version`, and the workspaces/runtimes.
   - `ps -o user,args -C multica` shows exactly one daemon, owned by `hermes`.
   - The runtime shows online in Multica (`multica runtime list --output json`).
   - Dashboard: HTTP 401/login page on the public URL (auth gate active), and the
     gateway is up (`hermes gateway status` as `hermes`).

## Rollback

- Code/config: in Railway, redeploy the previous successful deployment, or revert the
  commit and push. The volume is untouched, so Multica login and Hermes state stay.
- Upstream Hermes regression: pin the base image by digest
  (`FROM nousresearch/hermes-agent@sha256:<previous>`) and redeploy.
- Multica regression: set `MULTICA_VERSION` back to the previous version and redeploy.
  As a stopgap, set `MULTICA_DAEMON=0` to keep Hermes up without the runtime.
- Data impact: none from this repo. A newer Hermes may have migrated `/opt/data`,
  so roll back across Hermes versions only together with a volume backup.
