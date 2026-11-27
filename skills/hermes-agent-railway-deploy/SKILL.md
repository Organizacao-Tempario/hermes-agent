---
name: hermes-agent-railway-deploy
description: Deploy, configure, verify and roll back the Tempario Hermes Agent service on Railway (repo Organizacao-Tempario/hermes-agent), including the s6-supervised Multica daemon that runs as the hermes user and the always-latest multica/claude CLIs. Use for any release, config change, health check or incident on the Hermes Railway container.
---

# Hermes Agent on Railway

Repo: `https://github.com/Organizacao-Tempario/hermes-agent`. It is a thin
wrapper over the upstream image `nousresearch/hermes-agent`, **pinned by digest**.
Renovate (`renovate.json`) opens a PR when upstream `latest` moves, and when any pinned
tool release changes.

| File | Role |
| --- | --- |
| `Dockerfile` | `FROM nousresearch/hermes-agent:latest`, installs the pinned GitHub CLI (`GH_VERSION`) into `/opt/hermes-railway/bin`, copies `bin/update-agent-clis`, registers the `multica-daemon` s6 service, and sets `CMD` to `start.sh`. multica and claude are **not** baked in |
| `docker/install-tools.sh` | Build-time agent toolbox. From apt: `jq`, `shellcheck`, `psql`, `redis-cli`, `sqlite3`. Pinned and checksum-verified: `yq`, `hadolint`, `gitleaks`, `trivy`, `uv`/`uvx`, `railway`. `railway` has no upstream checksum |
| `docker/smoke-test.sh`, `.github/workflows/ci.yml` | CI: shellcheck, hadolint and gitleaks, then image build, a boot smoke test on a fresh volume, and a Trivy report |
| `bin/update-agent-clis` | Runs as hermes on every service start and installs or upgrades multica and claude to their **latest** releases in `/opt/data/.local/bin` |
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

- **Always latest, never pinned.** The binary is `/opt/data/.local/bin/multica` on the volume.
  - On every service start, `update-agent-clis` resolves the latest GitHub release, verifies it against
    `checksums.txt`, and swaps it in. A network failure keeps the existing copy.
  - While running, the daemon's own auto-update and auto-reload stay **on** (the defaults).
- **Self-update handoff.** Outside systemd, an updating daemon spawns a detached successor and exits 0.
  s6 then re-runs `run`, which sees a healthy daemon in `multica daemon status`. It supervises that PID
  (watches it and forwards TERM) instead of starting a second daemon. When the PID exits, s6 restarts
  the service normally.
- Runs as `hermes` with `HOME=/opt/data` and a clean environment (`env -i`). `NX_DAEMON=false` is set by default,
  because leaked Nx daemons count against the container's 1000-process limit.
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
- If multica can't be installed on first boot (no network), `run` retries every ~30s.
- If the service is disabled or the volume has no login, `run` writes
  `/run/multica-daemon.down` and `finish` exits 125, so the slot stays down and
  does not restart in a loop. To recover by hand, run
  `su -s /bin/sh hermes -c 'HOME=/opt/data /opt/data/.local/bin/multica login'` and then
  `s6-svc -u /run/service/multica-daemon`.
- Never start a second daemon by hand (`multica daemon start`) inside the
  container. It competes with the supervised one for `daemon.lock`.
  Never kill `multica` processes by name. Check `multica daemon status --output json` for the PID first.

## GitHub CLI (`gh`)

- `/opt/hermes-railway/bin/gh` is pinned by `ARG GH_VERSION` and checksum-verified. To upgrade, bump the version and redeploy.
- Daemon PATH order: `/opt/hermes-railway/bin` (gh) → `/opt/data/.local/bin` (latest multica, claude) → `/opt/hermes/bin` → `/usr/local/bin`.
  The image's gh therefore wins over the old gh symlink on the volume.
- Auth lives on the volume (`/opt/data/.config/gh`). Set it up once as hermes with
  `su -s /bin/sh hermes -c 'HOME=/opt/data gh auth login'`, or export `GH_TOKEN` in `/opt/data/.profile`.
  Railway variables do **not** reach agent runs because the daemon starts with `env -i`.
- To verify: `su -s /bin/sh hermes -c 'HOME=/opt/data gh auth status'`.

## Claude Code CLI (`claude`)

- **Always latest, never pinned.** The native install lives on the volume (`/opt/data/.local/bin/claude` →
  `/opt/data/.local/share/claude/versions/<v>`).
  - On every service start, `update-agent-clis` installs it with the official installer
    (`https://claude.ai/install.sh`, `latest` channel) if it is missing, and otherwise runs `claude update`.
  - Claude Code's own auto-updater stays on while it runs.
- Auth and config live on the volume (`/opt/data/.claude`, `/opt/data/.claude.json`) and survive redeploys.
- To verify: `su -s /bin/sh hermes -c 'HOME=/opt/data /opt/data/.local/bin/claude --version'`.
  The daemon status should list `claude` under `agents`.

## Plugins (boot-time update)

- Plugins live on the volume (`/opt/data/plugins`, per profile under `/opt/data/profiles/<name>/plugins`),
  so the image cannot update them at build time.
- `start.sh` runs `hermes plugins check-updates` then `hermes plugins update --yes` on every boot,
  before the gateway starts. It is bounded by `HERMES_PLUGINS_UPDATE_TIMEOUT` (default 300 s) and is
  never fatal. Opt out with `HERMES_PLUGINS_UPDATE_ON_BOOT=0`.
- No `--force`: a plugin whose security scan returns a caution verdict is skipped and logged.
- Between deploys the gateway's own auto-update (`hermes plugins auto-update`, every 24 h) keeps them current.
- Self-cloned plugins (status `self-cloned; run hermes plugins adopt first`) are not updated until adopted.
- Do not install the same plugin in two profiles: the shared-venv sync puts every profile's plugin
  sources into one uv workspace and fails with `Two workspace members are both named ...` (TEM-159).
- Verify: `hermes pm status` shows the latest sync receipt with `"outcome": "ok"`.

## Release checklist

1. **Scope**: commit/PR and target Railway environment. A base-image bump arrives as a Renovate PR
   that changes the digest in `FROM`. Note the old digest; it is the rollback target.
2. **Build**: CI (`ci` workflow) must be green: lint, build and the boot smoke test. Railway builds the Dockerfile. Locally, run `docker build .` and check that
   the `gh --version` line prints during the build. multica and claude are installed at container
   start. Their versions appear in the logs as `[update-agent-clis] multica: … / claude: …`.
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
   - Logs show `[update-agent-clis] multica: …` and `claude: …` lines (expect the latest releases),
     then `[multica-daemon] starting multica <version> as hermes`.
   - Logs show `[start] plugins: checking for updates` with no `update failed` line, and
     `hermes pm status` reports `"outcome": "ok"`.
   - In the container: `s6-svstat /run/service/multica-daemon`, which should be up with a growing uptime.
   - `su -s /bin/sh hermes -c 'HOME=/opt/data /opt/data/.local/bin/multica daemon status --output json'`
     should show `status: running`, the expected `cli_version`, and the workspaces/runtimes.
   - `ps -o user,args -C multica` shows exactly one daemon, owned by `hermes`.
   - The runtime shows online in Multica (`multica runtime list --output json`).
   - Dashboard: HTTP 401/login page on the public URL (auth gate active), and the
     gateway is up (`hermes gateway status` as `hermes`).

## Rollback

- Code/config: in Railway, redeploy the previous successful deployment, or revert the
  commit and push. The volume is untouched, so Multica login and Hermes state stay.
- Bad plugin update: a redeploy does not roll it back (plugins are on the volume). Set
  `HERMES_PLUGINS_UPDATE_ON_BOOT=0`, then reinstall the previous version (`hermes plugins remove <name>`,
  `hermes plugins install <source> --ref <40-char-sha>`) and restart the gateway.
- Upstream Hermes regression: revert the Renovate digest bump, so `FROM` points at the previous
  digest again, and redeploy.
- Bad multica/claude release: these always track latest, so a redeploy does **not** roll them back.
  - Stopgap: set `MULTICA_DAEMON=0` to keep Hermes up without the runtime.
  - Or replace `/opt/data/.local/bin/multica` with the previous release tarball as hermes and restart the
    service. Auto-update will move it forward again once a fixed release ships.
  - For claude, run `claude install <version>` as hermes.
- Data impact: none from this repo. A newer Hermes may have migrated `/opt/data`,
  so roll back across Hermes versions only together with a volume backup.
