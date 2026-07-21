#!/usr/bin/env bash
# ============================================================================
# claudelxc - Claude Code LXC Deployer for Proxmox
# Creates a fully provisioned Ubuntu 26.04 LXC container ready for Claude Code,
# then hands it over to an idempotent converge that also self-updates nightly.
#
# Run on your Proxmox host:
#   bash <(curl -fsSL https://raw.githubusercontent.com/serversathome/claudelxc/stable/install.sh)
#
# Env overrides (advanced):
#   CLAUDELXC_REPO   git URL to clone into the box   (default: this repo)
#   CLAUDELXC_BRANCH branch the box tracks + pulls   (default: stable)
#
# GitHub: https://github.com/serversathome/claudelxc
# ============================================================================

set -euo pipefail

REPO="${CLAUDELXC_REPO:-https://github.com/serversathome/claudelxc.git}"
BRANCH="${CLAUDELXC_BRANCH:-stable}"
CHECKOUT="/opt/claudelxc"

# ── Colors & Helpers ────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

header() {
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║        Claude Code LXC Deployer (Proxmox)        ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
}

# ── Pre-flight checks ──────────────────────────────────────────────────────
preflight() {
  [[ $(id -u) -eq 0 ]] || error "This script must be run as root on the Proxmox host."
  command -v pct   &>/dev/null || error "pct not found. Are you running this on a Proxmox host?"
  command -v pveam &>/dev/null || error "pveam not found. Are you running this on a Proxmox host?"
}

# ── Template Resolution ─────────────────────────────────────────────────────
resolve_template() {
  info "Resolving latest Ubuntu 26.04 LXC template from catalog..."
  pveam update >/dev/null 2>&1 || true
  local found
  found=$(pveam available --section system 2>/dev/null \
            | awk '{print $NF}' \
            | grep -E '^ubuntu-26\.04-standard' \
            | sort -V | tail -n1)
  if [[ -n "$found" ]]; then
    TEMPLATE="$found"; success "Using template: $TEMPLATE"
  else
    TEMPLATE="ubuntu-26.04-standard_26.04-1_amd64.tar.zst"
    warn "No 26.04 template found in catalog; using fallback name: $TEMPLATE"
    warn "Verify with: pveam available --section system | grep ubuntu-26.04"
  fi
}

# ── Configuration ───────────────────────────────────────────────────────────
get_config() {
  local next_id
  next_id=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")
  resolve_template

  echo -e "${BOLD}Container Configuration${NC}"
  echo "─────────────────────────────────────────────────"
  read -rp "Container ID [$next_id]: " CT_ID
  CT_ID="${CT_ID:-$next_id}"
  [[ "$CT_ID" =~ ^[0-9]+$ ]] || error "Container ID must be a number."
  pct status "$CT_ID" &>/dev/null && error "Container ID $CT_ID already exists."

  read -rp "Hostname [claude-code]: " CT_HOSTNAME
  CT_HOSTNAME="${CT_HOSTNAME:-claude-code}"

  read -rsp "Root password: " CT_PASSWORD; echo ""
  [[ -n "$CT_PASSWORD" ]] || error "Password cannot be empty."

  read -rp "CPU cores [4]: " CT_CORES;  CT_CORES="${CT_CORES:-4}"
  read -rp "RAM in MB [10240]: " CT_RAM; CT_RAM="${CT_RAM:-10240}"
  read -rp "Swap in MB [2048]: " CT_SWAP; CT_SWAP="${CT_SWAP:-2048}"
  read -rp "Disk size in GB [30]: " CT_DISK; CT_DISK="${CT_DISK:-30}"
  read -rp "Storage [truenas-lvm]: " CT_STORAGE; CT_STORAGE="${CT_STORAGE:-truenas-lvm}"

  read -rp "IP address (DHCP or x.x.x.x/xx) [dhcp]: " CT_IP
  CT_IP="${CT_IP:-dhcp}"
  if [[ "$CT_IP" != "dhcp" ]]; then
    read -rp "Gateway: " CT_GW
    [[ -n "$CT_GW" ]] || error "Gateway is required for static IP."
  fi
  read -rp "DNS server [1.1.1.1]: " CT_DNS; CT_DNS="${CT_DNS:-1.1.1.1}"
  read -rp "Path to SSH public key (optional, press Enter to skip): " CT_SSH_KEY

  echo ""
  echo -e "${BOLD}Summary${NC}"
  echo "─────────────────────────────────────────────────"
  echo "  CT ID:     $CT_ID"
  echo "  Hostname:  $CT_HOSTNAME"
  echo "  Template:  $TEMPLATE"
  echo "  CPU:       $CT_CORES cores"
  echo "  RAM:       $CT_RAM MB ($(( CT_RAM / 1024 )) GB)"
  echo "  Swap:      $CT_SWAP MB"
  echo "  Disk:      ${CT_DISK}G on $CT_STORAGE"
  echo "  Network:   $CT_IP"
  echo "  DNS:       $CT_DNS"
  echo "  Tracks:    $REPO ($BRANCH) — nightly self-update"
  echo "─────────────────────────────────────────────────"
  echo ""
  read -rp "Proceed? (y/N): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
}

# ── Download Ubuntu 26.04 Template ─────────────────────────────────────────
get_template() {
  info "Checking for template: $TEMPLATE"
  if ! pveam list local 2>/dev/null | grep -q "$TEMPLATE"; then
    info "Downloading $TEMPLATE ..."
    pveam download local "$TEMPLATE" || error "Failed to download template. Run 'pveam update' and try again."
  else
    success "Template already downloaded: $TEMPLATE"
  fi
  TEMPLATE_PATH="local:vztmpl/$TEMPLATE"
}

# ── Create Container ───────────────────────────────────────────────────────
create_container() {
  info "Creating LXC container $CT_ID..."
  local net_str="name=eth0,bridge=vmbr0"
  if [[ "$CT_IP" == "dhcp" ]]; then net_str+=",ip=dhcp"; else net_str+=",ip=$CT_IP,gw=$CT_GW"; fi

  local cmd=(
    pct create "$CT_ID" "$TEMPLATE_PATH"
    --hostname "$CT_HOSTNAME" --password "$CT_PASSWORD"
    --cores "$CT_CORES" --memory "$CT_RAM" --swap "$CT_SWAP"
    --rootfs "$CT_STORAGE:$CT_DISK" --net0 "$net_str" --nameserver "$CT_DNS"
    --ostype ubuntu --unprivileged 0 --features nesting=1,keyctl=1
    --onboot 1 --start 0
  )
  if [[ -n "${CT_SSH_KEY:-}" && -f "$CT_SSH_KEY" ]]; then cmd+=(--ssh-public-keys "$CT_SSH_KEY"); fi
  "${cmd[@]}"
  success "Container $CT_ID created."

  info "Setting AppArmor profile to unconfined (required for Docker)..."
  echo "lxc.apparmor.profile: unconfined" >> "/etc/pve/lxc/${CT_ID}.conf"
}

# ── Start & Wait for Network ──────────────────────────────────────────────
start_container() {
  info "Starting container $CT_ID..."
  pct start "$CT_ID"; sleep 3
  info "Waiting for network..."
  local attempts=0
  while ! pct exec "$CT_ID" -- ping -c1 -W2 1.1.1.1 &>/dev/null; do
    ((attempts++)); [[ $attempts -lt 30 ]] || error "Container failed to get network after 60s."
    sleep 2
  done
  success "Container is online."
}

# ── Bootstrap: clone claudelxc into the box, record config, run converge ────
bootstrap_container() {
  info "Bootstrapping container (installing git + cloning claudelxc @ $BRANCH)..."
  pct exec "$CT_ID" -- bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq git ca-certificates" \
    || error "Failed to install git in the container."
  pct exec "$CT_ID" -- rm -rf "$CHECKOUT"
  pct exec "$CT_ID" -- git clone --depth 1 --branch "$BRANCH" "$REPO" "$CHECKOUT" \
    || error "Failed to clone $REPO ($BRANCH) into the container."
  pct exec "$CT_ID" -- mkdir -p /etc/claudelxc
  pct exec "$CT_ID" -- bash -c "printf 'REPO=%s\nBRANCH=%s\nCHECKOUT=%s\n' '$REPO' '$BRANCH' '$CHECKOUT' > /etc/claudelxc/install.conf"

  info "Running converge (this takes a few minutes)..."
  pct exec "$CT_ID" -- "$CHECKOUT/guest/converge.sh" \
    || warn "Converge reported errors; check output above and run 'claudelxc-doctor' in the box."
}

# ── Write Proxmox Notes ─────────────────────────────────────────────────────
write_notes() {
  local ct_ip
  ct_ip=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}')
  ct_ip="${ct_ip:-<container-ip>}"

  local notes
  notes=$(cat <<'EOF'
# 🤖 Claude Code Container

**Web UI (CloudCLI UI):** http://__IP__:3001 — _create a login on first visit_
**SSH:** `ssh root@__IP__`   |   **Console:** `pct enter __CTID__`

## Start Claude Code
Log in, then run `claude` (the shell auto-cd's to `/project`).

## Update & health
- **Self-updates nightly** from the `claudelxc` repo (stable branch): pulls the
  latest deploy logic, re-applies it, refreshes packages, runs a health check.
- `claudelxc-update` — force a full update pass now. Log: `/var/log/claudelxc-update.log`
- `claudelxc-doctor` — run the health check on its own
- Auto-runs daily at 4 AM ET. (Delete `/etc/cron.d/claudelxc` to disable.)

## Service & config
- `systemctl status cloudcli` — the Web UI service (`journalctl -u cloudcli` for logs)
- Permissions: **auto mode** + secret deny-floor — `/root/.claude/settings.json`
- Deploy source of truth: `/opt/claudelxc` (git checkout)

---
_IP above is the address at deploy time; on DHCP it may change (check with `pct exec __CTID__ -- hostname -I`)._
EOF
)
  notes=${notes//__IP__/$ct_ip}
  notes=${notes//__CTID__/$CT_ID}
  if pct set "$CT_ID" --description "$notes" >/dev/null 2>&1; then
    success "Wrote container notes to the Proxmox UI."
  else
    warn "Could not set container notes (non-fatal)."
  fi
}

# ── Print Summary ─────────────────────────────────────────────────────────
print_summary() {
  local ct_ip
  ct_ip=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}')
  echo ""
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}║              Claude Code LXC Ready!               ║${NC}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}Container:${NC} $CT_ID ($CT_HOSTNAME)"
  echo -e "  ${BOLD}IP:${NC}        ${ct_ip:-pending (DHCP)}"
  echo -e "  ${BOLD}Resources:${NC} ${CT_CORES} CPU / $(( CT_RAM / 1024 )) GB RAM / ${CT_DISK} GB disk"
  echo ""
  echo -e "  ${BOLD}Connect:${NC}"
  echo -e "    Console: ${CYAN}pct enter $CT_ID${NC}"
  [[ -n "${ct_ip:-}" ]] && echo -e "    SSH:     ${CYAN}ssh root@${ct_ip}${NC}"
  [[ -n "${ct_ip:-}" ]] && echo -e "    Web UI:  ${CYAN}http://${ct_ip}:3001${NC} (CloudCLI UI — create a login on first visit)"
  echo ""
  echo -e "  ${BOLD}Start Claude Code:${NC} ${CYAN}claude${NC}  (shell auto-cd's to /project)"
  echo -e "  ${BOLD}Permissions:${NC} Auto mode (classifier-guarded) + deny floor for secrets"
  echo -e "  ${BOLD}Updates:${NC}     Self-updates nightly from ${BRANCH}. Force now: ${CYAN}claudelxc-update${NC}"
  echo -e "  ${BOLD}Health:${NC}      ${CYAN}claudelxc-doctor${NC}"
  echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────
main() {
  header
  preflight
  get_config
  get_template
  create_container
  start_container
  bootstrap_container
  write_notes
  print_summary
}

main "$@"
