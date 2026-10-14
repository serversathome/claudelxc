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
- **Web UI**: CloudCLI UI on port 3001 — chat, file explorer/editor, git, shell
- **Search tools**: ripgrep (rg), fd-find (fdfind), fzf
- **Databases**: PostgreSQL client (psql), Redis client (redis-cli), SQLite3

## Permissions
Permission mode is "auto" (permissions.defaultMode in ~/.claude/settings.json).
Actions are auto-approved but pass through a background safety classifier that
still blocks catastrophic commands (rm -rf /, rm -rf ~). A deny floor in
~/.claude/settings.json applies in every mode and blocks reading
credentials/secrets (.env, *.pem, id_rsa, .credentials.json, ~/.claude.json,
the CloudCLI auth DB) — do not try to work around it.

## Agent Teams
Agent teams are enabled (CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1; still
experimental). You can spawn parallel teammates for complex tasks:
- Use agent teams for work that benefits from parallel exploration
- Use subagents (the Agent tool) for quick focused work that reports back
- While teams are enabled, a *named* subagent launches as a teammate — leave
  subagents unnamed when you just want a worker that reports back
- Teammates run in-process by default; tmux is installed, so set
  `"teammateMode": "auto"` in ~/.claude/settings.json for split panes

## Remote Control
Remote Control lets you continue a session running on this box from the Claude
mobile app or claude.ai/code. Turn it on inside a session with `/remote-control`
(`/rc`), start a session with `claude --rc`, or run `claude remote-control` as a
headless server. To connect every session automatically, use `/config` →
"Enable Remote Control for all sessions" (it saves `remoteControlAtStartup` in
~/.claude/settings.json). Requires a claude.ai login (Pro/Max/Team/Enterprise;
API keys don't work), and the first use asks a one-time y/n confirmation, so do
it from an interactive shell.

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
- Thinking is adaptive on current models (no fixed budget is configured); use
  `/effort` to raise or lower effort for a session

## Staying up to date
This box self-updates from the `claudelxc` repo nightly — see `claudelxc-update`.
It pulls the latest deploy logic from the tracked branch, re-applies the
idempotent converge (so improvements to the deployer reach this box on their own),
then refreshes packages and runs a health check. Your logins, credentials, and
files under /project are preserved across updates. This file is a seed written
only on first deploy — edit it freely; the updater will not overwrite it.

## Installed Plugins / Skills
Plugins are installed with the `claude plugin` CLI at provision time, which also
writes them into `enabledPlugins` in `/root/.claude/settings.json`; the managed
template declares the same set so nightly converges re-enable them. Run
`claude plugin list` to confirm what's active. Plugins you add yourself survive
the nightly merge — it only forces the managed keys.
- **frontend-design**: Production-grade UI with distinctive aesthetics (auto-activates on frontend tasks)
- **code-review**: Multi-agent PR review with confidence scoring
- **commit-commands**: Git commit, push, and PR workflows (/commit, /push, /pr)
- **security-guidance**: Security warnings on edits, plus a diff/commit reviewer
- **claude-security**: On-demand deep vulnerability scan of your own code, with
  every finding challenged by a verification panel before it's reported
- **context7**: Live, version-specific library docs lookup (reduces API hallucinations)
- **modern-web-guidance**: Current web-platform best practices (View Transitions,
  container queries, `:has()`, Core Web Vitals) — counters stale training data on
  frontend work. Fetches guides over the network at query time via `npx`.
- **elements-of-style**: Strunk's writing rules, applied to docs, commit messages,
  and any prose a human will read
- **superpowers**: Development workflow framework — brainstorm → plan → implement with TDD
  - /superpowers:brainstorm — Refine ideas before coding
  - /superpowers:write-plan — Create implementation plans
  - /superpowers:execute-plan — Execute plans in batches via subagents
  - Auto-activating skills: test-driven-development, systematic-debugging, verification-before-completion
- **Language servers (LSP)**: `typescript-lsp`, `pyright-lsp`, `gopls-lsp`,
  `rust-analyzer-lsp`, `clangd-lsp` — go-to-definition, find-references, and
  real-time diagnostics for every toolchain on this box. The plugins are metadata
  only; converge installs the actual servers (typescript-language-server, pyright,
  gopls, rust-analyzer, clangd) onto PATH.
- **webapp-testing** (local skill, not a marketplace plugin): Playwright-based
  browser testing for UI verification and debugging
