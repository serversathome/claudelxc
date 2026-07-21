#!/usr/bin/env bash
# ============================================================================
# claudelxc converge - idempotent in-container setup.
#
# Runs INSIDE the LXC as root. Invoked once at deploy time by install.sh, and
# again on every nightly claudelxc-update. Re-running is safe: it refreshes
# MANAGED config (settings, systemd unit, skills, update tooling) and installs
# anything missing, while never touching USER STATE:
#   - /root/.claude/.credentials.json      (Claude login)
#   - /root/.cloudcli/auth.db              (CloudCLI UI login)
#   - files under /project                 (your work, incl. an edited CLAUDE.md)
#
# Deliberately NOT 'set -e': one step failing must not abort the rest (a browser
# download or a plugin install must never take down Docker/SSH/cron).
# ============================================================================
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATES="$REPO_DIR/templates"
BINDIR="$REPO_DIR/bin"
NPM_QUIET=(--no-fund --no-audit --loglevel=error)

log()  { echo ">>> $*"; }
warn() { echo "    [WARN] $*"; }

log "claudelxc converge starting (repo: $REPO_DIR)"

# ── Timezone ────────────────────────────────────────────────────────────────
log "Timezone -> America/New_York"
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
echo "America/New_York" > /etc/timezone
dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1 || true

# ── Locale ──────────────────────────────────────────────────────────────────
if ! locale -a 2>/dev/null | grep -qi 'en_US.utf8'; then
  log "Generating en_US.UTF-8 locale"
  apt-get update -qq
  apt-get install -y -qq locales
  sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen
  locale-gen en_US.UTF-8 >/dev/null 2>&1
  update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
fi

# ── OS packages: upgrade everything, then ensure the desired set is present ──
# apt upgrade runs on every converge (install AND nightly), so a box is fully
# patched from first boot. apt-get install is a no-op for packages already there.
log "Upgrading OS packages (apt update + upgrade)"
apt-get update -qq
apt-get upgrade -y -qq || warn "apt upgrade reported errors"
log "Ensuring base packages"
apt-get install -y -qq \
  git curl wget unzip zip \
  ca-certificates gnupg lsb-release apt-transport-https software-properties-common \
  bash-completion locales \
  htop nano vim tmux screen \
  jq yq tree \
  net-tools iproute2 iputils-ping dnsutils \
  openssh-server \
  cron logrotate \
  build-essential make cmake pkg-config autoconf automake libtool \
  python3 python3-pip python3-venv python3-dev \
  libssl-dev libffi-dev libsqlite3-dev zlib1g-dev \
  libreadline-dev libbz2-dev libncurses-dev liblzma-dev libxml2-dev libxslt-dev \
  ripgrep fd-find fzf bat \
  rsync sqlite3 \
  postgresql-client redis-tools \
  || warn "some base packages failed to install"

# ── Node.js (latest LTS) ────────────────────────────────────────────────────
if ! command -v node >/dev/null 2>&1; then
  log "Installing Node.js (latest LTS via NodeSource)"
  curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y -qq nodejs \
    || warn "Node.js install failed"
  npm install -g "${NPM_QUIET[@]}" npm@latest || warn "npm self-update failed"
fi
if command -v node >/dev/null 2>&1; then
  echo "    Node.js $(node --version 2>/dev/null) / npm $(npm --version 2>/dev/null)"
  # npm 12+ blocks dependencies' install scripts behind an allowlist, which
  # breaks native modules (CloudCLI's better-sqlite3/node-pty/bcrypt never
  # compile → the service crash-loops with "Could not locate the bindings
  # file" and nothing binds :3001). Restore pre-12 behavior so global installs
  # build their native addons. Persisted in /root/.npmrc, so it also covers the
  # updater's future cloudcli@latest upgrades and CloudCLI's in-app plugin builds.
  npm config set dangerously-allow-all-scripts true 2>/dev/null || true
  # Global dev tools — install only if absent (updater keeps them current).
  command -v prettier >/dev/null 2>&1 || \
    npm install -g "${NPM_QUIET[@]}" typescript ts-node eslint prettier || warn "global npm tools failed"
fi

# ── Go (latest) ─────────────────────────────────────────────────────────────
if [ ! -x /usr/local/go/bin/go ]; then
  log "Installing Go (latest)"
  GO_VERSION=$(curl -fsSL "https://go.dev/VERSION?m=text" | head -1)
  if [ -n "${GO_VERSION:-}" ] && curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz; then
    rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tar.gz && rm -f /tmp/go.tar.gz
    echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh
    echo "    Go $(/usr/local/go/bin/go version 2>/dev/null | awk '{print $3}')"
  else
    warn "Go install failed"
  fi
fi

# ── Rust (via rustup) ───────────────────────────────────────────────────────
if ! command -v rustc >/dev/null 2>&1 && [ ! -x "$HOME/.cargo/bin/rustc" ]; then
  log "Installing Rust (rustup)"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
    || warn "Rust install failed"
fi

# ── Docker + Compose ────────────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker"
  curl -fsSL https://get.docker.com | sh || warn "Docker install failed"
fi
if command -v docker >/dev/null 2>&1; then
  systemctl enable docker >/dev/null 2>&1 || true
  systemctl is-active --quiet docker || systemctl start docker || true
  dpkg -s docker-compose-plugin >/dev/null 2>&1 || apt-get install -y -qq docker-compose-plugin 2>/dev/null || true
fi

# ── Claude Code (native installer) ──────────────────────────────────────────
if ! command -v claude >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/claude" ]; then
  log "Installing Claude Code"
  curl -fsSL https://claude.ai/install.sh | bash || warn "Claude Code install failed"
fi
# Keep /usr/local/bin/claude pointing at the installed binary (idempotent).
if [ -x "$HOME/.local/bin/claude" ]; then
  ln -sf "$HOME/.local/bin/claude" /usr/local/bin/claude 2>/dev/null || true
elif [ -x "$HOME/.claude/bin/claude" ]; then
  ln -sf "$HOME/.claude/bin/claude" /usr/local/bin/claude 2>/dev/null || true
fi
CLAUDE_BIN="$(command -v claude || echo /usr/local/bin/claude)"
echo "    Claude Code: $("$CLAUDE_BIN" --version 2>/dev/null || echo 'version unknown')"

# ── Claude settings (MANAGED — overwritten every converge) ──────────────────
log "Writing Claude settings (auto mode + deny floor)"
mkdir -p /root/.claude
install -m 0644 "$TEMPLATES/settings.json" /root/.claude/settings.json

# ── Plugin marketplaces + plugins (idempotent; non-fatal) ───────────────────
log "Ensuring plugin marketplaces + plugins"
"$CLAUDE_BIN" plugin marketplace add anthropics/claude-plugins-official >/dev/null 2>&1 || true
"$CLAUDE_BIN" plugin marketplace add anthropics/claude-code            >/dev/null 2>&1 || true
"$CLAUDE_BIN" plugin marketplace add obra/superpowers-marketplace       >/dev/null 2>&1 || true

installed_plugins="$("$CLAUDE_BIN" plugin list 2>/dev/null || true)"
install_plugin() {
  local name="$1" mkt
  echo "$installed_plugins" | grep -q "$name" && { echo "    $name already installed"; return 0; }
  for mkt in claude-plugins-official claude-code-plugins; do
    if "$CLAUDE_BIN" plugin install "${name}@${mkt}" 2>/dev/null; then
      echo "    installed ${name}@${mkt}"; return 0
    fi
  done
  warn "could not install plugin: ${name}"
}
install_plugin frontend-design
install_plugin code-review
install_plugin commit-commands
install_plugin security-guidance
install_plugin context7
if echo "$installed_plugins" | grep -q superpowers; then
  echo "    superpowers already installed"
elif "$CLAUDE_BIN" plugin install superpowers@superpowers-marketplace 2>/dev/null; then
  echo "    installed superpowers@superpowers-marketplace"
else
  warn "could not install superpowers"
fi

# ── webapp-testing skill (MANAGED — refreshed every converge) ───────────────
log "Installing/refreshing webapp-testing skill"
if git clone --depth 1 --filter=blob:none --sparse https://github.com/anthropics/skills.git /tmp/anthropic-skills 2>/dev/null; then
  ( cd /tmp/anthropic-skills && git sparse-checkout set skills/webapp-testing >/dev/null 2>&1 )
  mkdir -p /root/.claude/skills
  rm -rf /root/.claude/skills/webapp-testing
  cp -r /tmp/anthropic-skills/skills/webapp-testing /root/.claude/skills/webapp-testing
  rm -rf /tmp/anthropic-skills
else
  warn "could not fetch webapp-testing skill (offline?); leaving existing copy"
fi

# ── Playwright (Python for the skill; Node global for CloudCLI Browser) ─────
# 26.04 isn't supported by Playwright yet (microsoft/playwright#40117); force the
# ubuntu24.04-x64 fallback build. Guard the Chromium download so we don't re-pull
# ~600MB every nightly run — install it only when the cache has no chromium build.
export PLAYWRIGHT_HOST_PLATFORM_OVERRIDE=ubuntu24.04-x64
grep -q PLAYWRIGHT_HOST_PLATFORM_OVERRIDE /etc/environment 2>/dev/null \
  || echo 'PLAYWRIGHT_HOST_PLATFORM_OVERRIDE=ubuntu24.04-x64' >> /etc/environment

if ! pip show playwright >/dev/null 2>&1; then
  log "Installing Python Playwright (webapp-testing skill)"
  pip install --break-system-packages -q playwright || warn "pip install playwright failed"
fi
if ! command -v playwright >/dev/null 2>&1 && ! npm ls -g playwright >/dev/null 2>&1; then
  log "Installing global Node Playwright (CloudCLI Browser feature)"
  npm install -g "${NPM_QUIET[@]}" playwright || warn "global Playwright install failed"
fi
if ! ls -d /root/.cache/ms-playwright/chromium-* >/dev/null 2>&1; then
  log "Downloading Chromium (ubuntu24.04-x64 build)"
  python3 -m playwright install --with-deps chromium \
    || python3 -m playwright install chromium \
    || warn "Chromium download failed (retry later; 26.04 support: microsoft/playwright#40117)"
fi
unset PLAYWRIGHT_HOST_PLATFORM_OVERRIDE

# ── /project + seed CLAUDE.md (USER-EDITABLE — written only if absent) ───────
mkdir -p /project
if [ ! -f /project/CLAUDE.md ]; then
  log "Seeding /project/CLAUDE.md"
  install -m 0644 "$TEMPLATES/project-CLAUDE.md" /project/CLAUDE.md
else
  echo "    /project/CLAUDE.md exists — left as-is"
fi

# ── SSH (idempotent) ────────────────────────────────────────────────────────
sed -i "s/^#*PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config
sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config
systemctl enable ssh >/dev/null 2>&1 || true
systemctl restart ssh || true

# ── Shell environment (MANAGED BLOCK — replaced, never duplicated) ──────────
log "Applying managed .bashrc block"
BEGIN="# >>> claudelxc managed >>>"
END="# <<< claudelxc managed <<<"
touch /root/.bashrc
# Strip any prior managed block (and the legacy un-marked block from agentic.sh).
sed -i "/$BEGIN/,/$END/d" /root/.bashrc
sed -i '/# ── Claude Code Container ──/,/^cd \/project 2>\/dev\/null/d' /root/.bashrc
cat >> /root/.bashrc <<BASHRC
$BEGIN
export EDITOR=nano
export LANG=en_US.UTF-8
export TZ=America/New_York
export PATH="\$HOME/.local/bin:\$HOME/.claude/bin:\$HOME/.cargo/bin:/usr/local/go/bin:\$PATH"
alias ll="ls -lah --color=auto"
alias cls="clear"
alias ..="cd .."
alias ...="cd ../.."
alias gs="git status"
alias gl="git log --oneline -20"
alias dc="docker compose"
alias dps="docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
cd /project 2>/dev/null || true
$END
BASHRC

# ── Git defaults (idempotent) ───────────────────────────────────────────────
git config --global init.defaultBranch main
git config --global core.editor nano
git config --global pull.rebase false

# ── CloudCLI UI ─────────────────────────────────────────────────────────────
if ! command -v cloudcli >/dev/null 2>&1; then
  log "Installing CloudCLI UI"
  npm install -g "${NPM_QUIET[@]}" @cloudcli-ai/cloudcli \
    || warn "CloudCLI UI install failed (needs Node 22+ and build tools for node-pty)"
fi
CCUI_BIN="$(command -v cloudcli || echo /usr/bin/cloudcli)"
mkdir -p /root/.cloudcli
echo "    CloudCLI UI: $("$CCUI_BIN" version 2>/dev/null || echo 'version unknown')"

# Self-heal native modules: if CloudCLI's better-sqlite3 addon isn't compiled
# (e.g. it was installed under npm 12 before scripts were allowed, or an upgrade
# didn't rebuild), recompile — otherwise the service crash-loops and :3001 stays
# down. No-op once the binding is present, so it's cheap on a healthy re-converge.
CCUI_PKG="$(npm root -g 2>/dev/null)/@cloudcli-ai/cloudcli"
if [ -d "$CCUI_PKG/node_modules/better-sqlite3" ] && \
   ! ls "$CCUI_PKG/node_modules/better-sqlite3/build/Release/"*.node >/dev/null 2>&1; then
  log "Rebuilding CloudCLI native modules (better-sqlite3/node-pty/bcrypt)"
  ( cd "$CCUI_PKG" && npm rebuild >/dev/null 2>&1 ) || warn "CloudCLI native rebuild failed"
fi

# systemd unit (MANAGED) — write from template, reload+restart only on change so
# we don't drop live UI sessions on an unchanged nightly run.
log "Applying cloudcli.service unit"
NEW_UNIT="$(mktemp)"
sed "s#@CCUI_BIN@#${CCUI_BIN}#g" "$TEMPLATES/cloudcli.service" > "$NEW_UNIT"
if ! cmp -s "$NEW_UNIT" /etc/systemd/system/cloudcli.service 2>/dev/null; then
  install -m 0644 "$NEW_UNIT" /etc/systemd/system/cloudcli.service
  systemctl daemon-reload
  UNIT_CHANGED=1
fi
rm -f "$NEW_UNIT"
systemctl enable cloudcli >/dev/null 2>&1 || true
if [ "${UNIT_CHANGED:-0}" = 1 ]; then
  systemctl restart cloudcli || warn "cloudcli restart failed (check 'journalctl -u cloudcli')"
else
  systemctl is-active --quiet cloudcli || systemctl start cloudcli || warn "cloudcli failed to start"
fi

# ── Update tooling (MANAGED — copied from the repo each converge) ───────────
log "Installing update tooling (claudelxc-update / claudelxc-doctor)"
install -m 0755 "$BINDIR/claudelxc-update" /usr/local/bin/claudelxc-update
install -m 0755 "$BINDIR/claudelxc-doctor" /usr/local/bin/claudelxc-doctor
# Back-compat aliases for the old agentic-* names.
ln -sf /usr/local/bin/claudelxc-update /usr/local/bin/agentic-update
ln -sf /usr/local/bin/claudelxc-doctor /usr/local/bin/agentic-doctor

install -m 0644 "$TEMPLATES/cron.claudelxc" /etc/cron.d/claudelxc
rm -f /etc/cron.d/agentic-update   # remove the legacy weekly cron if present
cat > /etc/logrotate.d/claudelxc <<'LOGROTATE'
/var/log/claudelxc-update.log {
    monthly
    rotate 3
    compress
    missingok
    notifempty
}
LOGROTATE

# ── Tidy up apt ─────────────────────────────────────────────────────────────
apt-get -y -qq autoremove || true
apt-get -qq clean || true

log "claudelxc converge complete"
