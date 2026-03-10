#!/bin/bash
# =============================================================================
# backup-manual.sh — Interactive / on-demand backup
# Reads config from /etc/backup/backup.conf (same as backup.sh).
# Invocation:
#   - from desktop via backup.desktop (pkexec)
#   - terminal: sudo /opt/backup/backup-manual.sh
# Sends desktop notifications when a D-Bus session is reachable.
# =============================================================================
set -euo pipefail

CONFIG="/etc/backup/backup.conf"
if [[ ! -f "$CONFIG" ]]; then
    echo "ERROR: config file $CONFIG not found. Run install.sh first." >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG"

# ============================================================================

LOG() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# Works even when invoked as root via pkexec — PKEXEC_UID is set by pkexec.
notify() {
    local summary="$1" body="${2:-}" urgency="${3:-normal}"
    local actual_user uid

    if [[ -n "${PKEXEC_UID:-}" ]]; then
        actual_user=$(id -nu "$PKEXEC_UID" 2>/dev/null || true)
    else
        actual_user="${SUDO_USER:-$USER}"
    fi

    uid=$(id -u "$actual_user" 2>/dev/null || true)

    if [[ -n "$uid" && -S "/run/user/$uid/bus" ]]; then
        sudo -u "$actual_user" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
            notify-send -u "$urgency" -i drive-harddisk "Backup" "$summary${body:+\n$body}" \
            2>/dev/null || true
    fi
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "This script must be run as root (cryptsetup and mount require it)." >&2
        echo "Try: sudo /opt/backup/backup-manual.sh" >&2
        exit 1
    fi
}

unlock_drive() {
    if [[ -b "/dev/mapper/$LUKS_MAPPER" ]]; then
        LOG "Drive already unlocked at /dev/mapper/$LUKS_MAPPER — skipping open."
        return
    fi

    if [[ ! -b "$LUKS_DEVICE" ]]; then
        LOG "ERROR: LUKS device $LUKS_DEVICE not found. Is the drive plugged in?"
        notify "Drive not found" "$LUKS_DEVICE — is the backup drive plugged in?" critical
        exit 1
    fi

    if [[ ! -f "$LUKS_KEYFILE" ]]; then
        LOG "ERROR: Keyfile $LUKS_KEYFILE not found. Run install.sh first."
        notify "Keyfile missing" "$LUKS_KEYFILE not found" critical
        exit 1
    fi

    LOG "Unlocking $LUKS_DEVICE …"
    cryptsetup luksOpen "$LUKS_DEVICE" "$LUKS_MAPPER" --key-file="$LUKS_KEYFILE"
    LOG "Drive unlocked."
}

mount_drive() {
    if mountpoint -q "$MOUNT_POINT"; then
        LOG "Drive already mounted at $MOUNT_POINT — skipping mount."
        return
    fi

    mkdir -p "$MOUNT_POINT"
    mount "/dev/mapper/$LUKS_MAPPER" "$MOUNT_POINT"
    LOG "Mounted at $MOUNT_POINT."
}

run_backup() {
    local home_dir="/home/$SOURCE_USER"
    local exclude_args=()
    for pattern in "${EXCLUDES[@]}"; do
        exclude_args+=("--exclude=$pattern")
    done

    mkdir -p "$BACKUP_DEST"
    LOG "Backing up selected folders from $home_dir …"

    for dir in "${BACKUP_DIRS[@]}"; do
        local src="$home_dir/$dir"
        local dst="$BACKUP_DEST/$dir"
        if [[ ! -e "$src" ]]; then
            LOG "SKIP: $src does not exist."
            continue
        fi
        LOG "  rsync: $src"
        mkdir -p "$dst"
        rsync -aAXH --delete --info=stats1 \
            "${exclude_args[@]}" \
            "$src/" "$dst/" \
            >> "$LOG_FILE" 2>&1
    done

    LOG "All directories synced."
}

cleanup() {
    LOG "Unmounting and locking drive…"
    if mountpoint -q "$MOUNT_POINT"; then
        umount "$MOUNT_POINT"
    fi
    if [[ -b "/dev/mapper/$LUKS_MAPPER" ]]; then
        cryptsetup luksClose "$LUKS_MAPPER"
    fi
    LOG "Drive locked and unmounted."
}

trap cleanup EXIT

require_root
LOG "=== Manual backup started ==="
notify "Backup started" "Syncing /home/$SOURCE_USER — this may take a while…"

unlock_drive
mount_drive
run_backup

LOG "=== Manual backup finished ==="
notify "Backup finished" "$(date '+%H:%M') — check /var/log/backup.log for details."
