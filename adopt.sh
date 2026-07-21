#!/usr/bin/env bash
# ============================================================================
# claudelxc adopt - retrofit an EXISTING container into the self-updating fleet.
#
# For a box that was created by the old agentic.sh (or by hand) and is now
# "frozen" — it has Claude Code but no nightly self-update, so improvements to
# the deployer never reach it. Run this INSIDE that container as root:
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/serversathome/claudelxc/stable/adopt.sh)
#
# It does NOT recreate the container and does NOT touch your work. It only wires
# the box into the fleet, then hands off to the normal idempotent converge:
#   1. clone this repo into /opt/claudelxc
#   2. record /etc/claudelxc/install.conf (REPO / BRANCH / CHECKOUT)
#   3. run guest/converge.sh once (installs the nightly updater + everything else)
#
# After this, /etc/cron.d/claudelxc self-updates the box from the tracked branch
# every night — exactly like a freshly deployed box. Re-running adopt is safe.
#
# Overrides (env): CLAUDELXC_BRANCH (default: stable), CLAUDELXC_REPO.
# ============================================================================
set -euo pipefail

REPO="${CLAUDELXC_REPO:-https://github.com/serversathome/claudelxc.git}"
BRANCH="${CLAUDELXC_BRANCH:-stable}"
CHECKOUT=/opt/claudelxc

say() { echo ">>> $*"; }

# ── Preflight ───────────────────────────────────────────────────────────────
[ "$(id -u)" = 0 ] || { echo "adopt must run as root (inside the container)." >&2; exit 1; }
if [ ! -f /etc/os-release ] || ! grep -qi ubuntu /etc/os-release; then
  echo "[WARN] this doesn't look like an Ubuntu box; converge targets Ubuntu. Continuing anyway." >&2
fi
if ! command -v git >/dev/null 2>&1; then
  say "Installing git"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq && apt-get install -y -qq git
fi

say "Adopting this box into claudelxc (branch: $BRANCH)"

# ── Back up the managed files converge overwrites, so nothing is lost ────────
# settings.json is replaced with the managed template; keep the box's current
# copy alongside it. (User state — creds, /project, CloudCLI auth — is never
# touched by converge, so it needs no backup.)
if [ -f /root/.claude/settings.json ] && [ ! -f /root/.claude/settings.json.pre-claudelxc ]; then
  cp -a /root/.claude/settings.json /root/.claude/settings.json.pre-claudelxc
  say "Backed up existing settings.json -> settings.json.pre-claudelxc"
fi

# ── Get the repo onto the box (clone fresh, or fast-forward an existing one) ──
if [ -d "$CHECKOUT/.git" ]; then
  say "Refreshing existing checkout at $CHECKOUT"
  git -C "$CHECKOUT" fetch --depth 1 origin "$BRANCH"
  git -C "$CHECKOUT" reset --hard "origin/${BRANCH}"
else
  say "Cloning $REPO ($BRANCH) -> $CHECKOUT"
  rm -rf "$CHECKOUT"
  git clone --depth 1 --branch "$BRANCH" "$REPO" "$CHECKOUT"
fi

# ── Record what this box tracks (the nightly updater reads this) ─────────────
mkdir -p /etc/claudelxc
printf 'REPO=%s\nBRANCH=%s\nCHECKOUT=%s\n' "$REPO" "$BRANCH" "$CHECKOUT" > /etc/claudelxc/install.conf
say "Wrote /etc/claudelxc/install.conf"

# ── Hand off to the idempotent converge (best-effort, like the updater) ──────
# converge is 'set -uo pipefail' (not -e): one failing step warns but doesn't
# abort the rest. Don't let a single warning fail adopt before the health check.
set +e
say "Running converge (this installs the nightly updater + brings the box up to spec)..."
"$CHECKOUT/guest/converge.sh"
crc=$?

echo
if command -v claudelxc-doctor >/dev/null 2>&1; then
  say "Health check:"
  claudelxc-doctor
fi

echo
if [ "$crc" -eq 0 ]; then
  say "Adopted. This box now self-updates nightly from '$BRANCH' (see /etc/cron.d/claudelxc)."
  say "Run 'claudelxc-update' any time to update on demand; 'claudelxc-doctor' to check health."
else
  say "Converge reported errors (exit $crc). Review the output above and re-run 'claudelxc-update'."
fi
exit "$crc"
