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

step_write_config() {
    header "Step 6 — Write config"

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
CONF

    chmod 640 "$CONF_DEST"
    chown root:root "$CONF_DEST"
    ok "Config written to $CONF_DEST"
}

step_install_files() {
    header "Step 7 — Install project files"

    mkdir -p "$INSTALL_DIR"

    # Scripts
    install -m 700 "$SCRIPT_DIR/backup.sh"        "$INSTALL_DIR/backup.sh"
    install -m 700 "$SCRIPT_DIR/backup-manual.sh" "$INSTALL_DIR/backup-manual.sh"
    ok "Scripts → $INSTALL_DIR/"

    # Assets + docs
    # Keep README.md and backup.conf in project root; other assets live in extras/
    [[ -f "$SCRIPT_DIR/README.md" ]] && install -m 644 "$SCRIPT_DIR/README.md" "$INSTALL_DIR/README.md" || true
    [[ -f "$SCRIPT_DIR/backup.conf" ]] && install -m 644 "$SCRIPT_DIR/backup.conf" "$INSTALL_DIR/backup.conf" || true
    if [[ -d "$SCRIPT_DIR/extras" ]]; then
        [[ -f "$SCRIPT_DIR/extras/backup-icon.svg" ]] && install -m 644 "$SCRIPT_DIR/extras/backup-icon.svg" "$INSTALL_DIR/backup-icon.svg" || true
        [[ -f "$SCRIPT_DIR/extras/CHANGELOG.md" ]] && install -m 644 "$SCRIPT_DIR/extras/CHANGELOG.md" "$INSTALL_DIR/CHANGELOG.md" || true
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
    echo "  Config:       $CONF_DEST"
    echo "  Scripts:      $INSTALL_DIR/"
    echo "  Log:          /var/log/backup.log"
    echo "  Timer:        $(systemctl is-active backup.timer 2>/dev/null || echo unknown)"
    echo ""
    echo "  Manual backup:   sudo $INSTALL_DIR/backup-manual.sh"
    echo "  Check timer:     systemctl status backup.timer"
    echo "  Watch log:       journalctl -u backup.service -f"
    echo ""
    echo -e "  Edit ${BOLD}$CONF_DEST${NC} to add/remove backup folders at any time."
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
step_write_config
step_install_files
step_summary

