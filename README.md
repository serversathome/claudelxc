# claudelxc

Turn a fresh Proxmox host into a fully provisioned **Claude Code LXC** with one
command — Ubuntu 26.04, Claude Code (auto mode), the CloudCLI UI web front end, a
full dev toolchain (Node/Python/Go/Rust/Docker), and a curated set of plugins and
skills. Once deployed, the box **keeps itself up to date on its own**.

## Deploy

Run on your **Proxmox host** (as root):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/serversathome/claudelxc/stable/install.sh)
```

Answer the prompts (container ID, resources, network). The installer creates the
LXC, clones this repo into it at `/opt/claudelxc`, and runs the idempotent
converge. When it finishes you get a browser link to the CloudCLI UI on `:3001`.

## How updates work

This is the important part, and it's modeled on
[homelabhero](https://github.com/serversathome/homelabhero)'s `hh-update`:

- The in-container setup lives in **`guest/converge.sh`** — an **idempotent** script
  that is the single source of truth for how a box is configured. Re-running it
  refreshes *managed* config (Claude settings, the CloudCLI systemd unit, skills,
  the update tooling) and installs anything missing, while never touching *user
  state* (your Claude/CloudCLI logins and your files under `/project`).
- Every box runs **`claudelxc-update`** nightly (via `/etc/cron.d/claudelxc`). It
  `git pull`s the latest from the branch it tracks, re-runs the converge, then
  refreshes the OS, Claude Code, the CloudCLI UI, and container images, and ends
  with a health check (`claudelxc-doctor`). Log: `/var/log/claudelxc-update.log`.

So when this repo improves, **already-deployed boxes pick up the change on their
own** — no rebuild, no manual migration.

Force an update any time:

```bash
claudelxc-update      # full pass now
claudelxc-doctor      # just the health check
```

## Branches (release channel)

- **`stable`** — what deployed boxes track and pull nightly. Treat it as
  latest-known-good.
- **`main`** — development. Changes land here first.

Promote when you're confident:

```bash
git checkout stable && git merge --ff-only main && git push && git checkout main
```

Because boxes track `stable`, work-in-progress on `main` never reaches the fleet
until you promote it. (Nothing is version-pinned — `stable` simply tracks the
newest commit you've blessed.)

## Layout

```
install.sh            # Proxmox host: create the LXC, then bootstrap + converge
guest/converge.sh     # idempotent in-container setup (the source of truth)
bin/claudelxc-update  # nightly: pull stable -> converge -> refresh packages -> doctor
bin/claudelxc-doctor  # health check
templates/            # managed config: settings.json, cloudcli.service, cron, /project seed
```

## Notes

- Public repo → boxes clone anonymously; **no credentials are stored on them**.
- A box that self-updates nightly is running whatever is on `stable`. Keep that
  branch trustworthy; that's the whole point of the two-branch split.
- Advanced overrides when deploying: `CLAUDELXC_REPO` and `CLAUDELXC_BRANCH`
  environment variables (e.g. track `main` on a test box).
