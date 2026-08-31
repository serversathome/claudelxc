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

set -Eeuo pipefail

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

# Never die silently: any command that trips `set -e` says so, with a line number.
trap 'rc=$?; echo -e "\n${RED}[ERROR]${NC} install.sh aborted at line ${LINENO} (exit ${rc}).\n        Please report this with the output above: https://github.com/serversathome/claudelxc/issues" >&2' ERR

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
  [[ -t 0 ]] || error "This installer is interactive but stdin is not a terminal.
        Use process substitution rather than a pipe:
          bash <(curl -fsSL https://raw.githubusercontent.com/serversathome/claudelxc/stable/install.sh)"
}

# ── Host discovery helpers ──────────────────────────────────────────────────
# Every one of these is guarded: a failing pvesh/pvesm/ip call must degrade to a
# sane default, never abort the installer (`set -e` + `pipefail`).

# First storage that can hold container rootfs; prefer the previous hard-coded
# default if it still exists on this host, else local-lvm, else whatever is there.
default_rootdir_storage() {
  local stores
  stores=$(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 {print $1}') || stores=""
  local pref
  for pref in truenas-lvm local-lvm local-zfs local; do
    grep -qx "$pref" <<<"$stores" && { echo "$pref"; return 0; }
  done
  head -n1 <<<"$stores" | grep . || echo "local-lvm"
}

storage_exists() {
  local stores
  stores=$(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 {print $1}') || return 0
  [[ -z "$stores" ]] && return 0          # can't tell — let pct decide
  grep -qx "$1" <<<"$stores"
}

# Storage that holds LXC templates (vztmpl). Nearly always "local".
default_template_storage() {
  local stores
  stores=$(pvesm status --content vztmpl 2>/dev/null | awk 'NR>1 {print $1}') || stores=""
  grep -qx local <<<"$stores" && { echo local; return 0; }
  head -n1 <<<"$stores" | grep . || echo local
}

default_bridge() {
  local bridges
  bridges=$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}') || bridges=""
  grep -qx vmbr0 <<<"$bridges" && { echo vmbr0; return 0; }
  head -n1 <<<"$bridges" | grep . || echo vmbr0
}

# ── Template Resolution ─────────────────────────────────────────────────────
resolve_template() {
  info "Resolving latest Ubuntu 26.04 LXC template from catalog..."
  pveam update >/dev/null 2>&1 || true

  # `pveam available` prints "<section> <template> <arch>" on PVE 9+ and
  # "<section> <template>" on older releases, so never index a fixed column
  # ($NF is the architecture on PVE 9, not the template). Split the whole
  # listing on whitespace and match the template filename itself instead.
  #
  # Every step here is guarded: with `set -e -o pipefail` an unguarded
  # `found=$(... | grep ...)` aborts the installer the moment grep matches
  # nothing, which is exactly what made this exit silently right after the
  # line above — the fallback below was never reached.
  local host_arch catalog found
  host_arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
  catalog=$( { pveam available --section system 2>/dev/null || true; } | tr -s '[:space:]' '\n' )

  found=$(printf '%s\n' "$catalog" \
            | grep -E "^ubuntu-26\\.04-standard_.*_${host_arch}\\.tar\\.(zst|xz|gz)$" \
            | sort -V | tail -n1) || found=""
  if [[ -z "$found" ]]; then
    found=$(printf '%s\n' "$catalog" \
              | grep -E '^ubuntu-26\.04-standard_.*\.tar\.(zst|xz|gz)$' \
              | sort -V | tail -n1) || found=""
  fi

  if [[ -n "$found" ]]; then
    TEMPLATE="$found"; success "Using template: $TEMPLATE"
  else
    TEMPLATE="ubuntu-26.04-standard_26.04-1_${host_arch}.tar.zst"
    warn "No 26.04 template found in the catalog; using fallback name: $TEMPLATE"
    warn "If the download below fails, check the catalog with:"
    warn "  pveam update && pveam available --section system | grep ubuntu-26.04"
  fi
}

# ── Configuration ───────────────────────────────────────────────────────────
get_config() {
  local next_id def_storage def_bridge pair
  next_id=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")
  def_storage=$(default_rootdir_storage)
  def_bridge=$(default_bridge)
  TEMPLATE_STORAGE=$(default_template_storage)
  resolve_template

  echo -e "${BOLD}Container Configuration${NC}"
  echo "─────────────────────────────────────────────────"
  read -rp "Container ID [$next_id]: " CT_ID
  CT_ID="${CT_ID:-$next_id}"
  [[ "$CT_ID" =~ ^[0-9]+$ ]] || error "Container ID must be a number."
  pct status "$CT_ID" &>/dev/null && error "Container ID $CT_ID already exists."

  read -rp "Hostname [claude-code]: " CT_HOSTNAME
  CT_HOSTNAME="${CT_HOSTNAME:-claude-code}"

  # Proxmox rejects root passwords shorter than 5 characters — catch it here
  # rather than after every other prompt, at `pct create`.
  read -rsp "Root password: " CT_PASSWORD; echo ""
  [[ -n "$CT_PASSWORD" ]] || error "Password cannot be empty."
  [[ ${#CT_PASSWORD} -ge 5 ]] || error "Password must be at least 5 characters (Proxmox requirement)."
  read -rsp "Confirm root password: " CT_PASSWORD2; echo ""
  [[ "$CT_PASSWORD" == "$CT_PASSWORD2" ]] || error "Passwords do not match."

  read -rp "CPU cores [4]: " CT_CORES;  CT_CORES="${CT_CORES:-4}"
  read -rp "RAM in MB [10240]: " CT_RAM; CT_RAM="${CT_RAM:-10240}"
  read -rp "Swap in MB [2048]: " CT_SWAP; CT_SWAP="${CT_SWAP:-2048}"
  read -rp "Disk size in GB [30]: " CT_DISK; CT_DISK="${CT_DISK:-30}"
  for pair in "CPU cores:$CT_CORES" "RAM:$CT_RAM" "Swap:$CT_SWAP" "Disk size:$CT_DISK"; do
    [[ "${pair#*:}" =~ ^[0-9]+$ ]] || error "${pair%%:*} must be a whole number (got '${pair#*:}')."
  done
  [[ "$CT_CORES" -ge 1 ]] || error "CPU cores must be at least 1."
  [[ "$CT_RAM"   -ge 512 ]] || error "RAM must be at least 512 MB."
  [[ "$CT_DISK"  -ge 8 ]] || error "Disk must be at least 8 GB (the toolchain alone needs several)."

  read -rp "Storage [$def_storage]: " CT_STORAGE; CT_STORAGE="${CT_STORAGE:-$def_storage}"
  storage_exists "$CT_STORAGE" || error "Storage '$CT_STORAGE' does not exist or cannot hold containers.
        Available: $(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 {printf "%s ", $1}')"

  read -rp "Network bridge [$def_bridge]: " CT_BRIDGE; CT_BRIDGE="${CT_BRIDGE:-$def_bridge}"
  ip -o link show "$CT_BRIDGE" &>/dev/null || warn "Bridge '$CT_BRIDGE' not found on this host; pct create may fail."

  read -rp "IP address (DHCP or x.x.x.x/xx) [dhcp]: " CT_IP
  CT_IP="${CT_IP:-dhcp}"
  if [[ "$CT_IP" != "dhcp" ]]; then
    # pct needs CIDR notation; a bare address is silently useless otherwise.
    [[ "$CT_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] \
      || error "Static IP must be in CIDR form, e.g. 192.168.1.50/24 (got '$CT_IP')."
    read -rp "Gateway: " CT_GW
    [[ "$CT_GW" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || error "Gateway must be an IPv4 address."
  fi
  read -rp "DNS server [1.1.1.1]: " CT_DNS; CT_DNS="${CT_DNS:-1.1.1.1}"
  read -rp "Path to SSH public key (optional, press Enter to skip): " CT_SSH_KEY
  if [[ -n "${CT_SSH_KEY:-}" && ! -f "$CT_SSH_KEY" ]]; then
    error "SSH public key file not found: $CT_SSH_KEY (leave blank to skip)"
  fi

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
  echo "  Network:   $CT_IP on $CT_BRIDGE"
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
  local store="${TEMPLATE_STORAGE:-local}"
  if ! pveam list "$store" 2>/dev/null | grep -qF "$TEMPLATE"; then
    info "Downloading $TEMPLATE to storage '$store' ..."
    pveam download "$store" "$TEMPLATE" || error "Failed to download template '$TEMPLATE'.
        Check what the catalog offers with:
          pveam update && pveam available --section system | grep ubuntu-26.04"
  else
    success "Template already downloaded: $TEMPLATE"
  fi
  TEMPLATE_PATH="$store:vztmpl/$TEMPLATE"
}

# ── Create Container ───────────────────────────────────────────────────────
create_container() {
  info "Creating LXC container $CT_ID..."
  local net_str="name=eth0,bridge=${CT_BRIDGE:-vmbr0}"
  if [[ "$CT_IP" == "dhcp" ]]; then net_str+=",ip=dhcp"; else net_str+=",ip=$CT_IP,gw=$CT_GW"; fi

  local cmd=(
    pct create "$CT_ID" "$TEMPLATE_PATH"
    --hostname "$CT_HOSTNAME" --password "$CT_PASSWORD"
    --cores "$CT_CORES" --memory "$CT_RAM" --swap "$CT_SWAP"
    --rootfs "$CT_STORAGE:$CT_DISK" --net0 "$net_str" --nameserver "$CT_DNS"
    --ostype ubuntu --unprivileged 0 --features "nesting=1,keyctl=1"
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
    attempts=$(( attempts + 1 )); [[ $attempts -lt 30 ]] || error "Container failed to get network after 60s."
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
  ct_ip=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}') || ct_ip=""
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
  ct_ip=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}') || ct_ip=""
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
