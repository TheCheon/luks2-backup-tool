#!/bin/bash
# =============================================================================
# install.sh — Backup project setup wizard
# Run as root: sudo ./install.sh
# Installs everything to /opt/backup and /etc/backup, registers systemd units.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/backup"
ETC_DIR="/etc/backup"
KEYFILE="$ETC_DIR/backup.key"
CONF_SRC="$SCRIPT_DIR/backup.conf"
CONF_DEST="$ETC_DIR/backup.conf"

# Defaults overridden by step_local_backup
LOCAL_BACKUP_ENABLED="false"
LOCAL_BACKUP_DIR="/var/backup/snapshots"
LOCAL_BACKUP_KEEP=10
REMOTE_BACKUP_KEEP=10
MIN_FREE_GB=5

# ── helpers ──────────────────────────────────────────────────────────────────

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()     { echo -e "${RED}[ERR ]${NC}  $*" >&2; }
ask()     { echo -e "${BOLD}[  ? ]${NC}  $*"; }
header()  { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}"; }
confirm() {
    local prompt="${1:-Continue?} [y/N] "
    local ans
    read -rp "$(echo -e "      $prompt")" ans
    [[ "${ans,,}" == "y" ]]
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root."
        echo "  Try: sudo ./install.sh"
        exit 1
    fi
}

# ── step functions ───────────────────────────────────────────────────────────

step_detect_drive() {
    header "Step 1 — Detect backup drive"

    info "Scanning for LUKS2 partitions…"
    echo ""

    # List all LUKS2 block devices with their UUIDs
    local luks_devs
    luks_devs=$(lsblk -o NAME,TYPE,FSTYPE,UUID,MOUNTPOINT -J 2>/dev/null \
        | python3 -c "
import sys, json
data = json.load(sys.stdin)
def walk(nodes, parent=''):
    for n in nodes or []:
        dev = '/dev/' + n['name']
        fstype = n.get('fstype') or ''
        uuid = n.get('uuid') or ''
        mp = n.get('mountpoint') or ''
        if fstype == 'crypto_LUKS':
            print(f'{dev}|{uuid}|{mp}')
        walk(n.get('children'), dev)
walk(data.get('blockdevices',[]))
" 2>/dev/null || true)

    if [[ -z "$luks_devs" ]]; then
        warn "No LUKS partitions detected automatically."
        warn "Make sure the drive is plugged in."
        echo ""
        ask "Enter LUKS device path manually (e.g. /dev/sda1):"
        read -rp "      Path: " LUKS_DEVICE
    else
        echo "  Found LUKS partition(s):"
        local i=1
        local -a devs=()
        while IFS='|' read -r dev uuid mp; do
            echo -e "  ${BOLD}[$i]${NC}  $dev  (UUID: $uuid)${mp:+  ← mounted at $mp}"
            devs+=("$dev|$uuid")
            ((i++))
        done <<< "$luks_devs"
        echo ""

        if [[ ${#devs[@]} -eq 1 ]]; then
            IFS='|' read -r LUKS_DEVICE luks_uuid <<< "${devs[0]}"
            info "Auto-selected: $LUKS_DEVICE"
        else
            ask "Which one is your backup drive? Enter number:"
            local choice
            read -rp "      Choice: " choice
            IFS='|' read -r LUKS_DEVICE luks_uuid <<< "${devs[$((choice-1))]}"
        fi
    fi

    # Prefer by-uuid path for stability
    if blkid "$LUKS_DEVICE" &>/dev/null; then
        local real_uuid
        real_uuid=$(blkid -s UUID -o value "$LUKS_DEVICE" 2>/dev/null || true)
        if [[ -n "$real_uuid" && -e "/dev/disk/by-uuid/$real_uuid" ]]; then
            LUKS_DEVICE="/dev/disk/by-uuid/$real_uuid"
            ok "Using stable path: $LUKS_DEVICE"
        fi
    fi
}

step_configure_user() {
    header "Step 2 — Source user"

    # Default to the user who called sudo
    local default_user="${SUDO_USER:-$(logname 2>/dev/null || echo '')}"
    ask "Which user's home folder are we backing up? [${default_user}]"
    read -rp "      User: " SOURCE_USER
    SOURCE_USER="${SOURCE_USER:-$default_user}"

    if [[ ! -d "/home/$SOURCE_USER" ]]; then
        err "/home/$SOURCE_USER does not exist."
        exit 1
    fi
    ok "Source user: $SOURCE_USER  (home: /home/$SOURCE_USER)"
}

step_choose_dirs() {
    header "Step 3 — Select folders to back up"

    info "Directories found in /home/$SOURCE_USER:"
    echo ""
    local -a available=()
    while IFS= read -r d; do
        available+=("$d")
        echo "    $d"
    done < <(find "/home/$SOURCE_USER" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | sort)
    echo ""

    info "Default selection: Documents Downloads Pictures Videos Music Desktop .config .ssh .gnupg"
    ask "Press Enter to use defaults, or type a space-separated list of folder names:"
    read -rp "      Dirs: " dirs_input

    if [[ -z "$dirs_input" ]]; then
        BACKUP_DIRS=("Documents" "Downloads" "Pictures" "Videos" "Music" "Desktop" ".config" ".ssh" ".gnupg")
    else
        read -ra BACKUP_DIRS <<< "$dirs_input"
    fi

    echo ""
    info "Will back up: ${BACKUP_DIRS[*]}"
}

step_keyfile() {
    header "Step 4 — Keyfile"

    mkdir -p "$ETC_DIR"
    chmod 700 "$ETC_DIR"

    if [[ -f "$KEYFILE" ]]; then
        ok "Keyfile already exists at $KEYFILE — skipping generation."
        # Test it against the chosen device (resolve the by-uuid symlink first)
        local real_dev
        real_dev=$(readlink -f "$LUKS_DEVICE" 2>/dev/null || echo "$LUKS_DEVICE")
        info "Testing keyfile against $real_dev…"
        if cryptsetup luksOpen --test-passphrase --key-file="$KEYFILE" "$real_dev" 2>/dev/null; then
            ok "Keyfile is valid for this drive."
            KEYFILE_ALREADY_ENROLLED=true
        else
            warn "Keyfile exists but is NOT enrolled on this drive yet."
            KEYFILE_ALREADY_ENROLLED=false
        fi
        return
    fi

    info "Generating 512-byte random keyfile at $KEYFILE…"
    dd if=/dev/urandom bs=512 count=1 of="$KEYFILE" status=none
    chmod 400 "$KEYFILE"
    chown root:root "$KEYFILE"
    ok "Keyfile generated."
    KEYFILE_ALREADY_ENROLLED=false
}

step_enroll_keyfile() {
    header "Step 5 — Enroll keyfile in LUKS"

    if [[ "${KEYFILE_ALREADY_ENROLLED:-false}" == "true" ]]; then
        ok "Keyfile already enrolled — skipping."
        return
    fi

    local real_dev
    real_dev=$(readlink -f "$LUKS_DEVICE" 2>/dev/null || echo "$LUKS_DEVICE")

    info "Adding keyfile to LUKS on $real_dev."
    warn "You will be prompted for your existing LUKS passphrase."
    echo ""

    if cryptsetup luksAddKey "$real_dev" "$KEYFILE"; then
        ok "Keyfile enrolled successfully."
    else
        err "cryptsetup luksAddKey failed."
        err "You can retry manually:"
        err "  cryptsetup luksAddKey $real_dev $KEYFILE"
        exit 1
    fi

    # Verify
    info "Verifying keyfile…"
    if cryptsetup luksOpen --test-passphrase --key-file="$KEYFILE" "$real_dev"; then
        ok "Keyfile verified."
    else
        err "Keyfile verification failed — something went wrong."
        exit 1
    fi
}

step_local_backup() {
    header "Step 6 — Local snapshots"

    info "Local snapshots = read-only hardlink copies on THIS machine."
    info "Fast recovery from accidental deletions — no drive needed."
    info "Space-efficient: only changed files take new space per snapshot."
    echo ""

    ask "Enable local snapshots? [Y/n]"
    read -rp "      Choice: " _choice
    if [[ "${_choice,,}" == "n" ]]; then
        LOCAL_BACKUP_ENABLED="false"
        info "Local snapshots disabled."
        return
    fi
    LOCAL_BACKUP_ENABLED="true"

    ask "Snapshot directory? [${LOCAL_BACKUP_DIR}]"
    read -rp "      Path: " _path
    LOCAL_BACKUP_DIR="${_path:-$LOCAL_BACKUP_DIR}"

    ask "How many local snapshots to keep? [${LOCAL_BACKUP_KEEP}]"
    read -rp "      Count: " _keep
    LOCAL_BACKUP_KEEP="${_keep:-$LOCAL_BACKUP_KEEP}"

    mkdir -p "$LOCAL_BACKUP_DIR"
    chmod 755 "$LOCAL_BACKUP_DIR"
    ok "Local snapshots: $LOCAL_BACKUP_DIR  (keep: $LOCAL_BACKUP_KEEP)"
}

step_write_config() {
    header "Step 7 — Write config"

    mkdir -p "$ETC_DIR"

    # Build the BACKUP_DIRS bash array literal
    local dirs_literal
    dirs_literal=$(printf '    "%s"\n' "${BACKUP_DIRS[@]}")

    cat > "$CONF_DEST" <<CONF
# =============================================================================
# backup.conf — generated by install.sh on $(date '+%Y-%m-%d %H:%M:%S')
# Edit this file to change backup behaviour.
# Re-run install.sh to regenerate from scratch.
# =============================================================================

LUKS_DEVICE="$LUKS_DEVICE"
LUKS_MAPPER="backup_drive"
LUKS_KEYFILE="$KEYFILE"

MOUNT_POINT="/mnt/backup"
BACKUP_DEST="/mnt/backup/home-backup"

SOURCE_USER="$SOURCE_USER"

BACKUP_DIRS=(
$dirs_literal
)

EXCLUDES=(
    ".cache"
    "*/.cache"
    "*.tmp"
    "*.swp"
    "node_modules"
    "__pycache__"
    ".local/share/Trash"
    ".thumbnails"
    ".var/app/*/cache"
)

LOG_FILE="/var/log/backup.log"

# --- Snapshots ----------------------------------------------------------------
# Timestamped incremental snapshots with --link-dest (hardlink unchanged files).
REMOTE_BACKUP_KEEP=$REMOTE_BACKUP_KEEP

# --- Local snapshots ----------------------------------------------------------
LOCAL_BACKUP_ENABLED=$LOCAL_BACKUP_ENABLED
LOCAL_BACKUP_DIR="$LOCAL_BACKUP_DIR"
LOCAL_BACKUP_KEEP=$LOCAL_BACKUP_KEEP

# --- Disk space warning -------------------------------------------------------
MIN_FREE_GB=$MIN_FREE_GB
CONF

    chmod 640 "$CONF_DEST"
    chown root:root "$CONF_DEST"
    ok "Config written to $CONF_DEST"
}

step_tray() {
    header "Step 8 — Tray application"

    # Check Python3 + gi
    if ! python3 -c "import gi" 2>/dev/null; then
        warn "PyGObject (python3-gi) not found."
        warn "  Arch:   pacman -S python-gobject"
        warn "  Debian: apt install python3-gi python3-gi-cairo"
    fi

    # Check AppIndicator bindings
    if ! python3 -c "
import gi
for lib in ('AyatanaAppIndicator3', 'AppIndicator3'):
    try:
        gi.require_version(lib, '0.1')
        __import__('gi.repository.' + lib)
        exit(0)
    except Exception:
        pass
exit(1)
" 2>/dev/null; then
        warn "AppIndicator3 library not found."
        warn "  Arch:   pacman -S libayatana-appindicator"
        warn "  Debian: apt install gir1.2-ayatana-appindicator3-0.1"
        warn "  GNOME:  install gnome-shell-extension-appindicator"
    fi

    # Create status dir + initial file
    mkdir -p /var/lib/backup
    if [[ ! -f /var/lib/backup/status.json ]]; then
        printf '{\n  "status": "idle",\n  "last_backup": "",\n  "last_backup_result": "",\n  "current_operation": ""\n}\n' \
            > /var/lib/backup/status.json
    fi
    chmod 644 /var/lib/backup/status.json
    ok "Status dir: /var/lib/backup/"

    # Determine actual (non-root) user
    local actual_user="${SUDO_USER:-$SOURCE_USER}"
    local user_home; user_home=$(getent passwd "$actual_user" | cut -d: -f6)
    local user_systemd="$user_home/.config/systemd/user"

    if [[ -z "$user_home" || ! -d "$user_home" ]]; then
        warn "Could not locate home for $actual_user — skipping user service install."
        return
    fi

    mkdir -p "$user_systemd"
    install -m 644 "$SCRIPT_DIR/extras/backup-tray.service" "$user_systemd/backup-tray.service"
    chown -R "$actual_user:$actual_user" "$user_home/.config/systemd"
    ok "User service → $user_systemd/backup-tray.service"

    sudo -u "$actual_user" systemctl --user daemon-reload 2>/dev/null || true

    ask "Start the tray app automatically on login? [Y/n]"
    read -rp "      Choice: " _autostart
    if [[ "${_autostart,,}" == "n" ]]; then
        info "Autostart skipped. Enable later with:"
        info "  systemctl --user enable --now backup-tray.service"
        return
    fi

    if sudo -u "$actual_user" systemctl --user enable --now backup-tray.service 2>/dev/null; then
        ok "Tray service enabled and started."
    else
        warn "Could not auto-enable. Run manually as $actual_user:"
        warn "  systemctl --user enable --now backup-tray.service"
    fi
}

step_install_files() {
    header "Step 9 — Install project files"

    mkdir -p "$INSTALL_DIR"

    # Scripts
    install -m 700 "$SCRIPT_DIR/backup.sh"           "$INSTALL_DIR/backup.sh"
    install -m 700 "$SCRIPT_DIR/backup-manual.sh"    "$INSTALL_DIR/backup-manual.sh"
    install -m 755 "$SCRIPT_DIR/backup-tray.py"      "$INSTALL_DIR/backup-tray.py"
    install -m 755 "$SCRIPT_DIR/backup-status.sh"    "$INSTALL_DIR/backup-status.sh"
    ok "Scripts → $INSTALL_DIR/"

    # Assets + docs
    # Keep README.md and backup.conf in project root; other assets live in extras/
    [[ -f "$SCRIPT_DIR/README.md" ]] && install -m 644 "$SCRIPT_DIR/README.md" "$INSTALL_DIR/README.md" || true
    [[ -f "$SCRIPT_DIR/backup.conf" ]] && install -m 644 "$SCRIPT_DIR/backup.conf" "$INSTALL_DIR/backup.conf" || true
    if [[ -d "$SCRIPT_DIR/extras" ]]; then
        [[ -f "$SCRIPT_DIR/extras/backup-icon.svg" ]]        && install -m 644 "$SCRIPT_DIR/extras/backup-icon.svg"        "$INSTALL_DIR/backup-icon.svg"        || true
        [[ -f "$SCRIPT_DIR/extras/backup-icon-active.svg" ]] && install -m 644 "$SCRIPT_DIR/extras/backup-icon-active.svg" "$INSTALL_DIR/backup-icon-active.svg" || true
        [[ -f "$SCRIPT_DIR/extras/CHANGELOG.md" ]]           && install -m 644 "$SCRIPT_DIR/extras/CHANGELOG.md"           "$INSTALL_DIR/CHANGELOG.md"           || true
    fi
    ok "Docs + assets → $INSTALL_DIR/"

    # Systemd (units stored in extras/ in the repo)
    install -m 644 "$SCRIPT_DIR/extras/backup.service" /etc/systemd/system/backup.service
    install -m 644 "$SCRIPT_DIR/extras/backup.timer"   /etc/systemd/system/backup.timer
    systemctl daemon-reload
    ok "Systemd units installed."

    # Desktop entry (from extras)
    install -m 644 "$SCRIPT_DIR/extras/backup.desktop" /usr/share/applications/backup.desktop
    command -v update-desktop-database &>/dev/null \
        && update-desktop-database /usr/share/applications/ || true
    ok "Desktop entry installed."

    # Enable timer
    systemctl enable --now backup.timer
    ok "Timer enabled and started."
}

step_summary() {
    header "Done"
    echo ""
    echo -e "  ${GREEN}Installation complete.${NC}"
    echo ""
    echo "  Config:        $CONF_DEST"
    echo "  Scripts:       $INSTALL_DIR/"
    echo "  Log:           /var/log/backup.log"
    echo "  Status:        /var/lib/backup/status.json"
    echo "  Timer:         $(systemctl is-active backup.timer 2>/dev/null || echo unknown)"
    [[ "$LOCAL_BACKUP_ENABLED" == "true" ]] && echo "  Local snaps:   $LOCAL_BACKUP_DIR  (keep $LOCAL_BACKUP_KEEP)" || true
    echo ""
    echo "  Tray app:        python3 $INSTALL_DIR/backup-tray.py"
    echo "  Manual backup:   sudo $INSTALL_DIR/backup-manual.sh"
    echo "  CLI status:      $INSTALL_DIR/backup-status.sh"
    echo "  Check timer:     systemctl status backup.timer"
    echo "  Watch log:       tail -f /var/log/backup.log"
    echo ""
    echo -e "  Edit ${BOLD}$CONF_DEST${NC} to change backup folders or snapshot settings."
    echo ""
}

# ── main ─────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║     backup — install wizard          ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════╝${NC}"
echo ""

require_root
step_detect_drive
step_configure_user
step_choose_dirs
step_keyfile
step_enroll_keyfile
step_local_backup
step_write_config
step_install_files
step_tray
step_summary

