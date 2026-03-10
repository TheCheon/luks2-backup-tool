#!/bin/bash
# =============================================================================
# backup.sh — LUKS2 unlock + rsync backup (automated, systemd timer)
# Configuration: /etc/backup/backup.conf
# For manual / interactive use: backup-manual.sh
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

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "This script must be run as root (needed for cryptsetup and mount)." >&2
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
        exit 1
    fi

    if [[ ! -f "$LUKS_KEYFILE" ]]; then
        LOG "ERROR: Keyfile $LUKS_KEYFILE not found. Run install.sh first."
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
LOG "=== Backup started ==="
unlock_drive
mount_drive
run_backup
LOG "=== Backup finished ==="
