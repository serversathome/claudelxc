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
#   CLAUDELXC_TUI=0  plain questions instead of the full-screen form
#                    (same as running with --plain)
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

# storage_rows — the active storages that can hold container disks, most free
# space first: name<TAB>type<TAB>free KiB<TAB>total KiB.
storage_rows() {
  { pvesm status --content rootdir 2>/dev/null || true; } \
    | awk 'NR > 1 && $3 == "active" { printf "%s\t%s\t%s\t%s\n", $1, $2, $6, $4 }' \
    | sort -t$'\t' -k3,3nr
}

# The storage with the most free space; nothing is assumed about its name.
default_rootdir_storage() {
  local best
  best=$(storage_rows | head -n1 | cut -f1) || best=""
  echo "${best:-local-lvm}"
}

storage_exists() {
  local stores
  stores=$(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 {print $1}') || return 0
  [[ -z "$stores" ]] && return 0          # can't tell — let pct decide
  grep -qx "$1" <<<"$stores"
}

# storage_free <name> — its free space in KiB ("" if unknown).
storage_free() {
  awk -F'\t' -v n="$1" '$1 == n { print $3 }' <<<"$STORAGES"
}

# gib <KiB> — "412 GiB".
gib() { awk -v k="$1" 'BEGIN { printf "%.0f GiB", k / 1048576 }'; }

# Storage that holds LXC templates (vztmpl). Nearly always "local".
default_template_storage() {
  local stores
  stores=$(pvesm status --content vztmpl 2>/dev/null | awk 'NR>1 {print $1}') || stores=""
  grep -qx local <<<"$stores" && { echo local; return 0; }
  head -n1 <<<"$stores" | grep . || echo local
}

bridge_rows() {
  { ip -o link show type bridge 2>/dev/null || true; } | awk -F': ' '{ sub(/@.*/, "", $2); print $2 }' | sort -V
}

default_bridge() {
  local bridges
  bridges=$(bridge_rows) || bridges=""
  grep -qx vmbr0 <<<"$bridges" && { echo vmbr0; return 0; }
  head -n1 <<<"$bridges" | grep . || echo vmbr0
}

host_gateway() {
  { ip route show default 2>/dev/null || true; } | awk '{ print $3; exit }'
}

# id_in_use <id> — a container or VM on any node of the cluster has it.
id_in_use() {
  pct status "$1" &>/dev/null && return 0
  compgen -G "/etc/pve/nodes/*/lxc/$1.conf" >/dev/null && return 0
  compgen -G "/etc/pve/nodes/*/qemu-server/$1.conf" >/dev/null && return 0
  return 1
}

# ssh_key_files — public keys on this host that can be given to the container.
ssh_key_files() {
  local f
  for f in /root/.ssh/*.pub /root/.ssh/authorized_keys; do
    [[ -s "$f" ]] && echo "$f"
  done
  return 0
}

# problem <field> — what is wrong with that setting, or nothing.
problem() {
  local free
  case $1 in
    id)
      if ! [[ "$CT_ID" =~ ^[1-9][0-9]*$ ]] || (( CT_ID < 100 )); then echo "Container ID must be a number, 100 or higher."
      elif id_in_use "$CT_ID"; then echo "ID $CT_ID is already used by a container or VM."; fi ;;
    hostname)
      [[ "$CT_HOSTNAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] \
        || echo "Hostname: letters, digits and - only (not first or last)." ;;
    password)
      if [[ -z "$CT_PASSWORD" ]]; then echo "Set a root password."
      elif (( ${#CT_PASSWORD} < 5 )); then echo "The root password needs at least 5 characters (Proxmox requirement)."; fi ;;
    cores)
      if ! [[ "$CT_CORES" =~ ^[1-9][0-9]*$ ]]; then echo "CPU cores must be a whole number, 1 or more."
      elif (( CT_CORES > HOST_CORES )); then echo "This host only has $HOST_CORES CPU cores."; fi ;;
    ram)
      [[ "$CT_RAM" =~ ^[1-9][0-9]*$ ]] && (( CT_RAM >= 512 )) || echo "RAM must be a whole number of MB, 512 or more." ;;
    swap)
      [[ "$CT_SWAP" =~ ^[0-9]+$ ]] || echo "Swap must be a whole number of MB (0 = none)." ;;
    disk)
      [[ "$CT_DISK" =~ ^[1-9][0-9]*$ ]] && (( CT_DISK >= 8 )) || echo "Disk must be at least 8 GB (the toolchain alone needs several)." ;;
    storage)
      if ! storage_exists "$CT_STORAGE"; then echo "Storage '$CT_STORAGE' does not exist or cannot hold containers."
      else
        free=$(storage_free "$CT_STORAGE")
        if [[ "$free" =~ ^[0-9]+$ && "$CT_DISK" =~ ^[0-9]+$ ]] && (( free < CT_DISK * 1048576 )); then
          echo "$CT_STORAGE has only $(gib "$free") free; the disk needs $CT_DISK GB."
        fi
      fi ;;
    bridge)
      ip -o link show "$CT_BRIDGE" &>/dev/null || echo "There is no bridge '$CT_BRIDGE' on this host." ;;
    ip)
      [[ "$CT_IP" == dhcp || "$CT_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] \
        || echo "Static IP must be in CIDR form, e.g. 192.168.1.50/24." ;;
    gw)
      [[ "$CT_IP" == dhcp || "$CT_GW" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || echo "A static IP needs a gateway (an IPv4 address)." ;;
    dns)
      [[ "$CT_DNS" =~ ^[0-9A-Fa-f:.]+$ ]] || echo "DNS server must be an IP address." ;;
    sshkey)
      [[ -z "$CT_SSH_KEY" || -f "$CT_SSH_KEY" ]] || echo "SSH public key file not found: $CT_SSH_KEY" ;;
  esac
  return 0
}

FIELDS="id hostname password cores ram swap disk storage bridge ip gw dns sshkey"

# problems — every setting's problem, one per line.
problems() {
  local f
  for f in $FIELDS; do problem "$f"; done
}

# ── Full-screen form ────────────────────────────────────────────────────────
# On a terminal that can show it, the settings are one full-screen form
# (Python's curses, part of python3's standard library): arrow keys, Enter to
# change a setting, Esc = back. Without python3, on a terminal that is too
# small or can't do it, or with --plain / CLAUDELXC_TUI=0, the questions are
# asked one by one. TUI_PY is the program; tui runs one screen of it.
TUI=0
TUI_TITLE="Claude Code LXC Deployer (Proxmox)"
read -r -d '' TUI_PY <<'PY' || true
import curses, locale, os, sys, textwrap

locale.setlocale(locale.LC_ALL, "")
os.environ.setdefault("ESCDELAY", "25")
UTF8 = "utf" in locale.getpreferredencoding(False).lower()
G = dict(up="↑↓", dot="●", bullet="•", line="─", more="…") if UTF8 else \
    dict(up="Up/Down", dot="*", bullet="*", line="-", more="...")
ENTER = ("\n", "\r", curses.KEY_ENTER)
BACKSPACE = (curses.KEY_BACKSPACE, "\x7f", "\x08")


class UI:
    def __init__(self, scr, title, text):
        self.scr, self.title, self.text = scr, title, text
        scr.keypad(True)
        self.cursor(0)
        rev, bold = curses.A_REVERSE, curses.A_BOLD
        self.bar = self.sel = rev
        self.bar |= bold
        self.dim, self.warn, self.good, self.accent = curses.A_DIM, bold, bold, bold
        if curses.has_colors():
            curses.start_color()
            bg = -1
            try:
                curses.use_default_colors()
            except curses.error:
                bg = curses.COLOR_BLACK
            curses.init_pair(1, curses.COLOR_WHITE, curses.COLOR_BLUE)
            curses.init_pair(2, curses.COLOR_BLACK, curses.COLOR_CYAN)
            curses.init_pair(3, curses.COLOR_YELLOW, bg)
            curses.init_pair(4, curses.COLOR_GREEN, bg)
            curses.init_pair(5, curses.COLOR_CYAN, bg)
            self.bar = curses.color_pair(1) | bold
            self.sel = curses.color_pair(2)
            self.warn = curses.color_pair(3) | bold
            self.good = curses.color_pair(4)
            self.accent = curses.color_pair(5) | bold

    @staticmethod
    def cursor(on):
        try:
            curses.curs_set(on)
        except curses.error:
            pass

    def put(self, y, x, s, attr=0):
        h, w = self.scr.getmaxyx()
        if not 0 <= y < h or x >= w - 1:
            return
        try:
            self.scr.addstr(y, x, s.replace("\t", " ")[: w - 1 - x], attr)
        except Exception:   # off-screen, or a character the terminal can't show
            pass

    # key — the next key. Arrow and page keys the terminal sends in a form its
    # terminfo entry doesn't list (e.g. ESC [ B instead of ESC O B) are
    # decoded here, so they don't read as Esc.
    SEQ = {"A": curses.KEY_UP, "B": curses.KEY_DOWN, "C": curses.KEY_RIGHT, "D": curses.KEY_LEFT,
           "H": curses.KEY_HOME, "F": curses.KEY_END, "1~": curses.KEY_HOME, "7~": curses.KEY_HOME,
           "4~": curses.KEY_END, "8~": curses.KEY_END, "3~": curses.KEY_DC,
           "5~": curses.KEY_PPAGE, "6~": curses.KEY_NPAGE}

    def key(self):
        try:
            k = self.scr.get_wch()
        except curses.error:
            return None
        if k != "\x1b":
            return k
        self.scr.nodelay(True)
        try:
            seq = ""
            try:
                c = self.scr.get_wch()
            except curses.error:
                return k
            if c not in ("[", "O"):
                return k
            while len(seq) < 6:
                try:
                    c = self.scr.get_wch()
                except curses.error:
                    break
                seq += c if isinstance(c, str) else ""
                if seq[-1:].isalpha() or seq[-1:] == "~":
                    break
            return self.SEQ.get(seq, None)
        finally:
            self.scr.nodelay(False)

    # frame <footer> — clear, title bar, footer bar. Returns (h, w).
    def frame(self, footer):
        self.scr.erase()
        h, w = self.scr.getmaxyx()
        self.put(0, 0, (" " + self.title).ljust(w), self.bar)
        self.put(h - 1, 0, (" " + footer).ljust(w), self.bar)
        return h, w

    # text <y> <max rows> — the screen's explanation, wrapped. Lines starting
    # with ⚠/! are warnings. Returns the rows used (plus a blank one).
    def text_block(self, y, maxrows):
        w = self.scr.getmaxyx()[1]
        lines = []
        for para in self.text.split("\n"):
            lines += textwrap.wrap(para, max(10, w - 5), break_on_hyphens=False) or [""]
        while lines and not lines[-1]:
            lines.pop()
        if not lines or maxrows <= 0:
            return 0
        if len(lines) > maxrows:
            lines = lines[: maxrows - 1] + [G["more"]]
        warn = False
        for i, l in enumerate(lines):
            if l[:1] in ("⚠", "!"):
                warn = True
            elif not l:
                warn = False
            self.put(y + i, 2, l, self.warn if warn else 0)
        return len(lines) + 1

    @staticmethod
    def scroll(top, cur, rows, n):
        if cur < top:
            top = cur
        elif cur >= top + rows:
            top = cur - rows + 1
        return max(0, min(top, n - rows))

    # nav <key> <cur> <n> <page> [selectable] — the new cursor for a movement
    # key, or None for any other key.
    @staticmethod
    def nav(k, cur, n, page, ok=lambda i: True):
        step = {curses.KEY_UP: -1, curses.KEY_DOWN: 1, curses.KEY_PPAGE: -page,
                curses.KEY_NPAGE: page, curses.KEY_HOME: -n, curses.KEY_END: n}.get(k)
        if step is None or n == 0:
            return None
        i = max(0, min(n - 1, cur + step))
        d = 1 if step > 0 else -1
        while not ok(i) and 0 <= i + d < n:
            i += d
        while not ok(i) and 0 <= i - d < n:
            i -= d
        return i if ok(i) else cur

    # menu — items "key<TAB>label[<TAB>hotkey]"; key "-" is a heading line.
    # Returns the key picked, None for Esc.
    def menu(self, default, items):
        ok = lambda i: items[i][0] != "-"
        idx = [i for i in range(len(items)) if ok(i)]
        if not idx:
            return None
        cur = next((i for i in idx if items[i][0] == default), idx[0])
        hot = {it[2].lower(): it[0] for it in items if len(it) > 2 and it[2]}
        top = 0
        while True:
            h, w = self.frame("%s move   Enter select   Esc back" % G["up"])
            y = 2 + self.text_block(2, h - 4 - min(len(items), 5))
            rows = max(1, h - 2 - y)
            top = self.scroll(top, cur, rows, len(items))
            for r in range(min(rows, len(items) - top)):
                i = top + r
                label = items[i][1] if len(items[i]) > 1 else items[i][0]
                if not ok(i):
                    self.put(y + r, 2, label, self.accent)
                else:
                    self.put(y + r, 2, (" " + label).ljust(w - 5), self.sel if i == cur else 0)
            if len(items) > rows:
                self.put(h - 2, 2, "%d of %d" % (idx.index(cur) + 1, len(idx)), self.dim)
            k = self.key()
            if k in ENTER:
                return items[cur][0]
            if isinstance(k, str) and k.lower() in hot:
                return hot[k.lower()]
            if k in ("\x1b", "q", curses.KEY_LEFT) + BACKSPACE:
                return None
            n = self.nav(k, cur, len(items), rows, ok)
            if n is not None:
                cur = n

    # input — one line of text, prefilled with the default. Returns it, None for Esc.
    def input(self, default, secret):
        buf, pos, off = list(default), len(default), 0
        while True:
            h, w = self.frame("Enter OK   Esc back   Ctrl-U clear")
            y = 2 + self.text_block(2, h - 6)
            fw = max(10, w - 8)
            if pos < off:
                off = pos
            elif pos > off + fw - 1:
                off = pos - fw + 1
            shown = "".join(G["bullet"] * len(buf) if secret else buf)
            self.put(y, 2, "> ", self.accent)
            self.put(y, 4, shown[off:off + fw].ljust(fw), self.sel)
            self.cursor(1)
            try:
                self.scr.move(y, 4 + pos - off)
            except curses.error:
                pass
            k = self.key()
            self.cursor(0)
            if k in ENTER:
                return "".join(buf)
            if k == "\x1b":
                return None
            if k in BACKSPACE:
                if pos:
                    del buf[pos - 1]
                    pos -= 1
            elif k == curses.KEY_DC:
                if pos < len(buf):
                    del buf[pos]
            elif k == curses.KEY_LEFT:
                pos = max(0, pos - 1)
            elif k == curses.KEY_RIGHT:
                pos = min(len(buf), pos + 1)
            elif k in (curses.KEY_HOME, "\x01"):
                pos = 0
            elif k in (curses.KEY_END, "\x05"):
                pos = len(buf)
            elif k == "\x15":
                buf, pos = [], 0
            elif isinstance(k, str) and k.isprintable():
                buf.insert(pos, k)
                pos += 1


def main():
    a = sys.argv[1:] + [""] * 5
    widget, title, text, default, out = a[:5]
    flags = sys.argv[6:]
    if widget == "probe":
        try:
            curses.setupterm()
            cols, lines = os.get_terminal_size(1)
        except Exception:
            return 3
        return 0 if cols >= 60 and lines >= 16 else 3
    items = [l.split("\t") for l in os.environ.get("TUI_ITEMS", "").split("\n") if l.strip()]

    def run(scr):
        ui = UI(scr, title, text)
        if widget == "menu":
            return ui.menu(default, items)
        if widget == "input":
            return ui.input(default, "secret" in flags)
        raise ValueError("unknown widget " + widget)
    try:
        res = curses.wrapper(run)
    except KeyboardInterrupt:
        return 130
    except Exception:
        import traceback
        traceback.print_exc()
        return 3
    if res is None:
        return 1
    with open(out, "w") as f:
        f.write(res)
    return 0


sys.exit(main())
PY

# tui_init — use the full-screen form if this terminal can show it (60x16 at least).
tui_init() {
  [[ "${CLAUDELXC_TUI:-1}" != 0 ]] || return 0
  command -v python3 &>/dev/null || return 0
  { : </dev/tty; } 2>/dev/null || return 0
  [[ "${TERM:-dumb}" != dumb ]] || return 0
  if python3 -c "$TUI_PY" probe </dev/tty >/dev/tty 2>/dev/null; then TUI=1; fi
  return 0
}

# tui <screen> <text> <default> [items] [flags...] — one full-screen step on the
# terminal, titled $TUI_TITLE; prints the answer. Returns 1 for Esc (back).
# Screens: menu (items "key<TAB>label[<TAB>hotkey]", key "-" = a heading) and
# input (flag "secret" hides what is typed).
tui() {
  local out rc=0
  out=$(mktemp)
  TUI_ITEMS=${4-} python3 -c "$TUI_PY" "$1" "$TUI_TITLE" "$2" "$3" "$out" "${@:5}" </dev/tty >/dev/tty 2>/dev/tty || rc=$?
  cat "$out"; rm -f "$out"
  case $rc in
    0|1) return $rc ;;
    130) echo "Aborted." >&2; kill -s TERM $$; exit 1 ;;   # Ctrl-C
    *) echo "The full-screen form failed. Run again with --plain for plain questions." >&2
       kill -s TERM $$; exit 1 ;;
  esac
}

# tui_msg <text> — show a message until Enter or Esc.
tui_msg() { tui menu "$1" ok $'ok\tOK' >/dev/null || true; }

# tui_yesno <text> <y|n> — Esc = no.
tui_yesno() {
  local a
  a=$(tui menu "$1" "$2" $'y\tYes\ty\nn\tNo\tn') || return 1
  [[ "$a" == y ]]
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
  NEXT_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")
  HOST_CORES=$(nproc 2>/dev/null || echo 1)
  HOST_RAM_MB=$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo 2>/dev/null || echo 0)
  STORAGES=$(storage_rows) || STORAGES=""
  BRIDGES=$(bridge_rows) || BRIDGES=""
  TEMPLATE_STORAGE=$(default_template_storage)
  resolve_template

  CT_ID=$NEXT_ID; CT_HOSTNAME=claude-code; CT_PASSWORD=""
  CT_CORES=$(( HOST_CORES < 4 ? HOST_CORES : 4 )); CT_RAM=10240; CT_SWAP=2048; CT_DISK=30
  CT_STORAGE=$(default_rootdir_storage); CT_BRIDGE=$(default_bridge)
  CT_IP=dhcp; CT_GW=""; CT_DNS=1.1.1.1; CT_SSH_KEY=""

  tui_init
  if [[ "$TUI" == 1 ]]; then form; print_config; else ask_config; fi
}

print_config() {
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
  echo "  Network:   $CT_IP on $CT_BRIDGE${CT_GW:+ (gateway $CT_GW)}"
  echo "  DNS:       $CT_DNS"
  echo "  Tracks:    $REPO ($BRANCH) — nightly self-update"
  echo "─────────────────────────────────────────────────"
  echo ""
}

# form — every setting on one full-screen form; Enter on one changes it, and
# "Create" is only taken once nothing is marked ⚠.
form() {
  local choice=id text bad
  while :; do
    bad=$(problems)
    text="Template: $TEMPLATE
This host: $HOST_CORES CPU cores, $(( HOST_RAM_MB / 1024 )) GB RAM. Pick a setting and press Enter to change it, then Create."
    [[ -n "$bad" ]] && text+=$'\n'"$(sed 's/^/⚠ /' <<<"$bad")"
    if ! choice=$(tui menu "$text" "$choice" "$(form_items)"); then
      tui_yesno "Quit without creating a container?" n && { echo "Aborted."; exit 0; }
      choice=id; continue
    fi
    if [[ "$choice" == @create ]]; then
      [[ -z "$bad" ]] && return 0
      tui_msg "Fix the settings marked ⚠ first."
      # Read all of form_items: stopping early (grep -m1) fails it under pipefail.
      choice=$(form_items | awk -F'\t' '/⚠/ && !f { print $1; f = 1 }')
      continue
    fi
    edit_field "$choice"
  done
}

# form_items — the form's rows: key<TAB>label and value (⚠ when wrong).
form_items() {
  local f label value free
  for f in $FIELDS; do
    case $f in
      id)       label="Container ID";  value=$CT_ID ;;
      hostname) label="Hostname";      value=$CT_HOSTNAME ;;
      password) label="Root password"; value=$([[ -n "$CT_PASSWORD" ]] && echo "set (hidden)" || echo "not set") ;;
      cores)    label="CPU cores";     value=$CT_CORES ;;
      ram)      label="RAM";           value="$CT_RAM MB" ;;
      swap)     label="Swap";          value="$CT_SWAP MB" ;;
      disk)     label="Disk size";     value="$CT_DISK GB" ;;
      storage)  label="Storage";       free=$(storage_free "$CT_STORAGE")
                value="$CT_STORAGE${free:+ ($(gib "$free") free)}" ;;
      bridge)   label="Network bridge"; value=$CT_BRIDGE ;;
      ip)       label="IP address";    value=$([[ "$CT_IP" == dhcp ]] && echo "DHCP" || echo "$CT_IP") ;;
      gw)       [[ "$CT_IP" == dhcp ]] && continue
                label="Gateway";       value=${CT_GW:-not set} ;;
      dns)      label="DNS server";    value=$CT_DNS ;;
      sshkey)   label="SSH public key"; value=${CT_SSH_KEY:-none} ;;
    esac
    printf '%s\t%-16s %s%s\n' "$f" "$label" "$value" "$([[ -n "$(problem "$f")" ]] && echo "   ⚠")"
  done
  printf -- '-\t\n@create\t▶ Create the container\n'
}

# edit_field <field> — change one setting. Esc keeps it as it was.
edit_field() {
  local v v2 items name type free total note
  case $1 in
    id)
      v=$(tui input "Container ID: 100 or higher, not used by another container or VM ($NEXT_ID is the next free one)." "$CT_ID") && CT_ID=$v ;;
    hostname)
      v=$(tui input "Hostname for the container:" "$CT_HOSTNAME") && CT_HOSTNAME=$v ;;
    password)
      if v=$(tui input "Root password for the container (5 characters or more):" "" secret) \
          && v2=$(tui input "Type the root password again:" "" secret); then
        if [[ "$v" == "$v2" ]]; then CT_PASSWORD=$v; else tui_msg "⚠ The passwords don't match; the password was not changed."; fi
      fi ;;
    cores)
      v=$(tui input "CPU cores (this host has $HOST_CORES):" "$CT_CORES") && CT_CORES=$v ;;
    ram)
      v=$(tui input "RAM in MB (10240 = 10 GB; this host has $HOST_RAM_MB MB):" "$CT_RAM") && CT_RAM=$v ;;
    swap)
      v=$(tui input "Swap in MB (0 = none):" "$CT_SWAP") && CT_SWAP=$v ;;
    disk)
      v=$(tui input "Disk size in GB (8 or more):" "$CT_DISK") && CT_DISK=$v ;;
    storage)
      if [[ -z "$STORAGES" ]]; then
        v=$(tui input "Proxmox didn't list any storage for container disks. Storage name:" "$CT_STORAGE") && CT_STORAGE=$v
      else
        items=""
        while IFS=$'\t' read -r name type free total; do
          note=""
          [[ "$CT_DISK" =~ ^[0-9]+$ ]] && (( free < CT_DISK * 1048576 )) && note="   too small for $CT_DISK GB"
          items+=$(printf '%s\t%-20s %-10s %9s free of %s%s' "$name" "$name" "$type" "$(gib "$free")" "$(gib "$total")" "$note")$'\n'
        done <<<"$STORAGES"
        v=$(tui menu "Storage for the container's disk: the storages on this host that can hold containers, most free space first." "$CT_STORAGE" "$items") && CT_STORAGE=$v
      fi ;;
    bridge)
      if [[ -z "$BRIDGES" ]]; then
        v=$(tui input "No bridges found on this host. Network bridge:" "$CT_BRIDGE") && CT_BRIDGE=$v
      else
        v=$(tui menu "Network bridge the container connects to:" "$CT_BRIDGE" "$(awk '{ print $1 "\t" $1 }' <<<"$BRIDGES")") && CT_BRIDGE=$v
      fi ;;
    ip)
      if v=$(tui menu "How does the container get its IP address?" "$([[ "$CT_IP" == dhcp ]] && echo dhcp || echo static)" \
          $'dhcp\tDHCP (your router hands one out)\nstatic\tStatic address...'); then
        if [[ "$v" == dhcp ]]; then
          CT_IP=dhcp
        elif v=$(tui input "Static IP address with its prefix length, e.g. 192.168.1.50/24:" "$([[ "$CT_IP" != dhcp ]] && echo "$CT_IP")"); then
          CT_IP=$v
          [[ -n "$CT_GW" ]] || CT_GW=$(host_gateway) || CT_GW=""
        fi
      fi ;;
    gw)
      v=$(tui input "Gateway for the static address:" "${CT_GW:-$(host_gateway)}") && CT_GW=$v ;;
    dns)
      v=$(tui input "DNS server:" "$CT_DNS") && CT_DNS=$v ;;
    sshkey)
      items=$( { ssh_key_files | awk '{ print $0 "\t" $0 }'; printf '@none\tNone\n@other\tAnother file...\n'; } )
      if v=$(tui menu "SSH public key to let in as root (optional):" "${CT_SSH_KEY:-@none}" "$items"); then
        case $v in
          @none) CT_SSH_KEY="" ;;
          @other) v=$(tui input "Path to an SSH public key file:" "$CT_SSH_KEY") && CT_SSH_KEY=$v ;;
          *) CT_SSH_KEY=$v ;;
        esac
      fi ;;
  esac
  return 0
}

# ask_config — the same settings as plain questions, one at a time.
ask_config() {
  local pair i def pick name type free total
  echo -e "${BOLD}Container Configuration${NC}"
  echo "─────────────────────────────────────────────────"
  read -rp "Container ID [$NEXT_ID]: " CT_ID
  CT_ID="${CT_ID:-$NEXT_ID}"
  [[ "$CT_ID" =~ ^[0-9]+$ ]] || error "Container ID must be a number."
  id_in_use "$CT_ID" && error "Container ID $CT_ID is already used by a container or VM."

  read -rp "Hostname [claude-code]: " CT_HOSTNAME
  CT_HOSTNAME="${CT_HOSTNAME:-claude-code}"

  # Proxmox rejects root passwords shorter than 5 characters — catch it here
  # rather than after every other prompt, at `pct create`.
  read -rsp "Root password: " CT_PASSWORD; echo ""
  [[ -n "$CT_PASSWORD" ]] || error "Password cannot be empty."
  [[ ${#CT_PASSWORD} -ge 5 ]] || error "Password must be at least 5 characters (Proxmox requirement)."
  read -rsp "Confirm root password: " CT_PASSWORD2; echo ""
  [[ "$CT_PASSWORD" == "$CT_PASSWORD2" ]] || error "Passwords do not match."

  read -rp "CPU cores [$CT_CORES]: " pick; CT_CORES="${pick:-$CT_CORES}"
  read -rp "RAM in MB [10240]: " CT_RAM; CT_RAM="${CT_RAM:-10240}"
  read -rp "Swap in MB [2048]: " CT_SWAP; CT_SWAP="${CT_SWAP:-2048}"
  read -rp "Disk size in GB [30]: " CT_DISK; CT_DISK="${CT_DISK:-30}"
  for pair in "CPU cores:$CT_CORES" "RAM:$CT_RAM" "Swap:$CT_SWAP" "Disk size:$CT_DISK"; do
    [[ "${pair#*:}" =~ ^[0-9]+$ ]] || error "${pair%%:*} must be a whole number (got '${pair#*:}')."
  done
  [[ "$CT_CORES" -ge 1 ]] || error "CPU cores must be at least 1."
  [[ "$CT_RAM"   -ge 512 ]] || error "RAM must be at least 512 MB."
  [[ "$CT_DISK"  -ge 8 ]] || error "Disk must be at least 8 GB (the toolchain alone needs several)."

  # Storage: picked from what this host has, most free space first.
  if [[ -n "$STORAGES" ]]; then
    echo "Storage for the container's disk:"
    i=0; def=1
    while IFS=$'\t' read -r name type free total; do
      i=$(( i + 1 ))
      printf '  %d) %-20s %-10s %9s free of %s\n' "$i" "$name" "$type" "$(gib "$free")" "$(gib "$total")"
      [[ "$name" == "$CT_STORAGE" ]] && def=$i
    done <<<"$STORAGES"
    read -rp "Storage [$def]: " pick; pick="${pick:-$def}"
    if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= i )); then
      CT_STORAGE=$(sed -n "${pick}p" <<<"$STORAGES" | cut -f1)
    else
      CT_STORAGE=$pick
    fi
  else
    read -rp "Storage [$CT_STORAGE]: " pick; CT_STORAGE="${pick:-$CT_STORAGE}"
  fi
  [[ -z "$(problem storage)" ]] || error "$(problem storage)
        Available: $(cut -f1 <<<"$STORAGES" | xargs)"

  read -rp "Network bridge [$CT_BRIDGE]${BRIDGES:+ ($(xargs <<<"$BRIDGES"))}: " pick; CT_BRIDGE="${pick:-$CT_BRIDGE}"
  ip -o link show "$CT_BRIDGE" &>/dev/null || warn "Bridge '$CT_BRIDGE' not found on this host; pct create may fail."

  read -rp "IP address (DHCP or x.x.x.x/xx) [dhcp]: " CT_IP
  CT_IP="${CT_IP:-dhcp}"
  if [[ "$CT_IP" != "dhcp" ]]; then
    # pct needs CIDR notation; a bare address is silently useless otherwise.
    [[ "$CT_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] \
      || error "Static IP must be in CIDR form, e.g. 192.168.1.50/24 (got '$CT_IP')."
    def=$(host_gateway) || def=""
    read -rp "Gateway${def:+ [$def]}: " CT_GW; CT_GW="${CT_GW:-$def}"
    [[ "$CT_GW" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || error "Gateway must be an IPv4 address."
  fi
  read -rp "DNS server [1.1.1.1]: " CT_DNS; CT_DNS="${CT_DNS:-1.1.1.1}"
  read -rp "Path to SSH public key (optional, press Enter to skip): " CT_SSH_KEY
  if [[ -n "${CT_SSH_KEY:-}" && ! -f "$CT_SSH_KEY" ]]; then
    error "SSH public key file not found: $CT_SSH_KEY (leave blank to skip)"
  fi

  print_config
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
  info "Waiting for network (DNS + outbound HTTPS to github.com)..."
  # Test what bootstrap actually needs — name resolution and an outbound TCP
  # connection — rather than ICMP, which some networks block and which proves
  # nothing about DNS. bash's /dev/tcp needs no extra packages in the template.
  local attempts=0
  while ! pct exec "$CT_ID" -- bash -c 'getent hosts github.com >/dev/null && timeout 5 bash -c "exec 3<>/dev/tcp/github.com/443"' &>/dev/null; do
    attempts=$(( attempts + 1 )); [[ $attempts -lt 30 ]] || error "Container failed to get network after 60s (check DNS '$CT_DNS', gateway, and the bridge '$CT_BRIDGE')."
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
  [[ "${1:-}" == --plain ]] && CLAUDELXC_TUI=0
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
