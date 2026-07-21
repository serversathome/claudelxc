# claudelxc — contributor guide

> **You're on `main`, the development branch.** Deployed boxes track **`stable`** and
> pull it nightly. Land changes here, test, then promote to `stable`. The user-facing
> README lives on the [`stable`](https://github.com/serversathome/claudelxc/tree/stable)
> branch.

One-command deployer that turns a Proxmox host into a **self-updating Claude Code LXC**.
Design goal: when this repo improves, already-deployed boxes converge to it on their own —
no rebuilds, no manual migration.

## Architecture

- **`install.sh`** (Proxmox host): interactive create → `pct create` → clone this repo into
  the box at `/opt/claudelxc` → run `guest/converge.sh`. Records
  `/etc/claudelxc/install.conf` (`REPO` / `BRANCH` / `CHECKOUT`).
- **`guest/converge.sh`** (in-container, **idempotent**): the single source of truth for how
  a box is configured. Safe to re-run — that re-runnability is what makes self-update work.
- **`bin/claudelxc-update`** (nightly cron): `git reset --hard origin/<branch>` → run converge
  → refresh OS / Claude Code / CloudCLI / container images → `claudelxc-doctor`.
- **`bin/claudelxc-doctor`**: health check.
- **`templates/`**: managed config — `settings.json`, `cloudcli.service`, `cron.claudelxc`,
  `project-CLAUDE.md` seed.

## The idempotency contract

Re-running converge must refresh **managed** config and never touch **user state**.

- **Managed** (overwritten every run): `settings.json`, the `cloudcli.service` unit, the
  update tooling, the `webapp-testing` skill.
- **User state** (never touched): `/root/.claude/.credentials.json` (Claude login),
  `/root/.cloudcli/auth.db` (CloudCLI login), everything under `/project` — including a
  user-edited `/project/CLAUDE.md` (seeded only if absent).
- **Mechanics that keep re-runs safe:** a marked `.bashrc` block (stripped + rewritten, never
  duplicated); the Chromium download is guarded so nightly runs don't re-pull ~600 MB;
  `cloudcli` is restarted only when its unit actually changes; `set -uo pipefail` (never `-e`)
  with per-step warnings so one failure never cascades.

## Branches

- **`main`** — development (this branch).
- **`stable`** — what boxes track + pull nightly; latest-known-good; the repo's default branch.

The two branches intentionally differ in **`README.md` only** (this dev doc vs. the user
guide). Keep code changes on `main`; never hand-edit code on `stable`.

## Promote `main` → `stable`

Because the branches diverge on `README.md`, a fast-forward merge won't work. Promote with a
merge that keeps `stable`'s own README:

```bash
git checkout stable
git merge --no-ff --no-commit main       # bring in main's changes
git checkout stable -- README.md         # keep stable's user-facing README
git add README.md && git commit --no-edit
git push
git checkout main
```

## Test a change before promoting

Deploy a throwaway box that tracks `main` (the `CLAUDELXC_BRANCH` override points both the
clone and the box's nightly self-update at `main`):

```bash
CLAUDELXC_BRANCH=main bash <(curl -fsSL https://raw.githubusercontent.com/serversathome/claudelxc/main/install.sh)
```

Then inside the box:
- `claudelxc-doctor` — should be all-green.
- `claudelxc-update` — exercises the full `pull → converge → refresh → doctor` loop; watch
  `/var/log/claudelxc-update.log`.
- Run converge twice and confirm idempotency: exactly one `claudelxc managed` block in
  `/root/.bashrc`, and logins + `/project` preserved.

## Layout

```
install.sh            # Proxmox host: create the LXC, then bootstrap + converge
guest/converge.sh     # idempotent in-container setup (the source of truth)
bin/claudelxc-update  # nightly: pull stable -> converge -> refresh packages -> doctor
bin/claudelxc-doctor  # health check
templates/            # managed config: settings.json, cloudcli.service, cron, /project seed
```
