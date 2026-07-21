# Claude Code Workspace

## Environment
- **OS**: Ubuntu 26.04 LXC container on Proxmox
- **Working directory**: /project
- **Timezone**: America/New_York
- **User**: root

## Available Tools
- **Languages**: Node.js (latest LTS), Python 3 (system default), Go (latest), Rust (latest)
- **Package managers**: npm, pip (use --break-system-packages), cargo, go install
- **Docker**: Docker Engine + Compose plugin, running and ready
- **Web UI**: CloudCLI UI (claudecodeui) on port 3001 — chat, file explorer/editor, git, shell
- **Search tools**: ripgrep (rg), fd-find (fdfind), fzf
- **Databases**: PostgreSQL client (psql), Redis client (redis-cli), SQLite3

## Permissions
Permission mode is "auto" (permissions.defaultMode). Actions are auto-approved
but pass through a background safety classifier that still blocks catastrophic
commands (rm -rf /, rm -rf ~). A deny floor in ~/.claude/settings.json applies in
every mode and blocks reading credentials/secrets (.env, *.pem, id_rsa,
.credentials.json) — do not try to work around it.

## Agent Teams
Agent teams are enabled. You can spawn parallel teammates for complex tasks:
- Use agent teams for work that benefits from parallel exploration
- Use subagents (Task tool) for quick focused work that reports back
- tmux is installed for split-pane team visualization

## Remote Control
Remote Control lets you steer a live local session from the Claude mobile app or
web. It is NOT enabled via settings.json — turn it on per session with `/rc`
(or `claude remote-control`), or for all sessions via `/config` →
"Enable Remote Control for all sessions". Requires a Pro/Max login (research
preview), so it only applies once someone signs in interactively.

## Docker Usage
Docker compose files should go in /docker/<service-name>/docker-compose.yml.
There is no always-on Watchtower daemon. Container images are refreshed one-shot
by the nightly `claudelxc-update` run (or on demand: `claudelxc-update`), so give
containers you want updated the usual `restart: unless-stopped`.
All Docker containers in this LXC need `security_opt: [apparmor=unconfined]`.

## Conventions
- Prefer creating files over printing long code blocks
- Use git for version control on all projects in /project/src/
- When installing Python packages, use: pip install --break-system-packages <package>
- Extended thinking is always on — use it for complex architectural decisions

## Staying up to date
This box self-updates from the `claudelxc` repo nightly — see `claudelxc-update`.
It pulls the latest deploy logic from the tracked branch, re-applies the
idempotent converge (so improvements to the deployer reach this box on their own),
then refreshes packages and runs a health check. Your logins, credentials, and
files under /project are preserved across updates. This file is a seed written
only on first deploy — edit it freely; the updater will not overwrite it.

## Installed Plugins / Skills
Plugins are installed via the `claude plugin` CLI at provision time (not via an
enabledPlugins block, which is ignored in containers). Run `claude plugin list`
to confirm what's active.
- **frontend-design**: Production-grade UI with distinctive aesthetics (auto-activates on frontend tasks)
- **code-review**: Multi-agent PR review with confidence scoring
- **commit-commands**: Git commit, push, and PR workflows (/commit, /push, /pr)
- **security-guidance**: Security warnings when editing sensitive files
- **context7**: Live, version-specific library docs lookup (reduces API hallucinations)
- **superpowers**: Development workflow framework — brainstorm → plan → implement with TDD
  - /superpowers:brainstorm — Refine ideas before coding
  - /superpowers:write-plan — Create implementation plans
  - /superpowers:execute-plan — Execute plans in batches via subagents
  - Auto-activating skills: test-driven-development, systematic-debugging, verification-before-completion
- **webapp-testing** (local skill, not a marketplace plugin): Playwright-based
  browser testing for UI verification and debugging
