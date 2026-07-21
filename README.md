# claudelxc

**Turn a Proxmox host into a fully provisioned, self-updating Claude Code box — with one command.**

`claudelxc` builds an Ubuntu 26.04 LXC running [Claude Code](https://claude.ai/code) in
permission **auto mode**, fronted by the **CloudCLI UI** web app, on top of a full dev
toolchain — and then keeps the whole thing up to date on its own.

## Quick start

Run on your **Proxmox host**, as root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/serversathome/claudelxc/stable/install.sh)
```

Answer a few prompts (container ID, CPU/RAM/disk, network). A few minutes later you get a
link to the web UI on port **3001**. Open it, create a login, and start talking to Claude.

## What you get

- **Claude Code** (native install) in auto mode — actions are auto-approved through a safety
  classifier, with a deny floor that always blocks reading secrets (`.env`, `*.pem`, keys) and
  catastrophic commands.
- **CloudCLI UI** on `:3001` — chat, file explorer/editor, git panel, and a built-in terminal,
  driving the same Claude Code under the hood.
- **Dev toolchain** — Node.js (LTS), Python 3, Go, Rust, Docker + Compose, plus git, ripgrep,
  fzf, fd, database clients, and build essentials.
- **Curated plugins & skills** — code-review, security-guidance, commit-commands,
  frontend-design, context7, superpowers, and a Playwright-based webapp-testing skill.
- **Agent teams** and extended thinking enabled out of the box.

## It keeps itself updated

Every box updates itself **nightly** — no action needed. It pulls the latest `claudelxc`,
re-applies the setup, then refreshes the OS, Claude Code, the web UI, and any container
images, and finishes with a health check. Your logins and everything under `/project` are
preserved across updates.

Force it any time from inside the box:

```bash
claudelxc-update      # full update pass right now
claudelxc-doctor      # just the health check
```

Update log: `/var/log/claudelxc-update.log`. To turn nightly updates off, delete
`/etc/cron.d/claudelxc`.

## Managing the box

- **Web UI service:** `systemctl status cloudcli` (`journalctl -u cloudcli` for logs)
- **Start Claude in a shell:** `claude` (drops you in `/project`)
- **Config:** `/root/.claude/settings.json` (permissions + env)
- **Console / SSH:** `pct enter <id>` from the host, or `ssh root@<box-ip>`

Deploy details (IP, update commands) are also written into the container's **Notes** panel in
the Proxmox UI.

## Good to know

- The box clones this **public** repo anonymously — **no credentials are stored on it**.
- It self-updates from the `stable` branch, which tracks the latest known-good release.
- Runs as root inside an unprivileged-by-choice LXC with nesting enabled for Docker.
