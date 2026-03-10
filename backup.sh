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

# ── constants ─────────────────────────────────────────────────────────────────
STATUSFILE="/var/lib/backup/status.json"
LOCKFILE="/var/run/backup.lock"
TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')

# ── helpers ──────────────────────────────────────────────────────────────────
LOG() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

write_status() {
    local st="$1" op="${2:-}"
    mkdir -p /var/lib/backup
    local last="" res=""
    if [[ -f "$STATUSFILE" ]]; then
        last=$(python3 -c "import json; d=json.load(open('$STATUSFILE')); print(d.get('last_backup',''))" 2>/dev/null || true)
        res=$( python3 -c "import json; d=json.load(open('$STATUSFILE')); print(d.get('last_backup_result',''))" 2>/dev/null || true)
    fi
    case "$st" in
        idle)   last=$(date -Iseconds); res="success" ;;
        failed) last=$(date -Iseconds); res="failed"  ;;
    esac
    printf '{\n  "status": "%s",\n  "last_backup": "%s",\n  "last_backup_result": "%s",\n  "current_operation": "%s"\n}\n' \
        "$st" "$last" "$res" "$op" > "$STATUSFILE"
    chmod 644 "$STATUSFILE"
}

acquire_lock() {
    if [[ -f "$LOCKFILE" ]]; then
        local pid; pid=$(cat "$LOCKFILE" 2>/dev/null || echo "")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            LOG "Backup already running (PID $pid). Aborting."
            exit 1
        fi
        rm -f "$LOCKFILE"
    fi
    echo $$ > "$LOCKFILE"
}

prune_snapshots() {
    local dir="$1" keep="${2:-10}"
    local -a snaps
    mapfile -t snaps < <(ls -1dt "$dir"/[0-9][0-9][0-9][0-9]-* 2>/dev/null || true)
    local count=${#snaps[@]}
    if (( count > keep )); then
        for old in "${snaps[@]:$keep}"; do
            LOG "Pruning old snapshot: $(basename "$old")"
            chmod -R u+w "$old" 2>/dev/null || true
            rm -rf "$old"
        done
    fi
}

check_space() {
    local dir="$1" min_gb="${MIN_FREE_GB:-5}"
    [[ -d "$dir" ]] || return 0
    local avail_kb; avail_kb=$(df -k "$dir" 2>/dev/null | awk 'NR==2{print $4}' || echo 99999999)
    (( avail_kb < min_gb * 1024 * 1024 )) \
        && LOG "WARNING: Less than ${min_gb}GB free on $dir" || true
}

require_root() { [[ $EUID -eq 0 ]] || { echo "Must be run as root." >&2; exit 1; }; }

# ── drive ops ─────────────────────────────────────────────────────────────────
unlock_drive() {
    if [[ -b "/dev/mapper/$LUKS_MAPPER" ]]; then
        LOG "Drive already unlocked — skipping."; return
    fi
    [[ -b "$LUKS_DEVICE" ]] || { LOG "ERROR: $LUKS_DEVICE not found. Plugged in?"; exit 1; }
    [[ -f "$LUKS_KEYFILE" ]] || { LOG "ERROR: Keyfile $LUKS_KEYFILE not found."; exit 1; }
    LOG "Unlocking $LUKS_DEVICE …"
    cryptsetup luksOpen "$LUKS_DEVICE" "$LUKS_MAPPER" --key-file="$LUKS_KEYFILE"
    LOG "Drive unlocked."
}

mount_drive() {
    mountpoint -q "$MOUNT_POINT" && { LOG "Already mounted — skipping."; return; }
    mkdir -p "$MOUNT_POINT"
    mount "/dev/mapper/$LUKS_MAPPER" "$MOUNT_POINT"
    LOG "Mounted at $MOUNT_POINT."
}

# ── backup ops ────────────────────────────────────────────────────────────────
_rsync_dirs() {
    # _rsync_dirs <dest> [extra rsync args...]
    local dest="$1"; shift
    local home_dir="/home/$SOURCE_USER"
    local -a excl=(); for p in "${EXCLUDES[@]}"; do excl+=("--exclude=$p"); done
    for dir in "${BACKUP_DIRS[@]}"; do
        local src="$home_dir/$dir"
        [[ -e "$src" ]] || { LOG "SKIP (not found): $dir"; continue; }
        write_status "running" "$dir"
        mkdir -p "$dest/$dir"
        LOG "  rsync: $dir"
        rsync -aAXH --delete --info=stats1 \
            "$@" "${excl[@]}" \
            "$src/" "$dest/$dir/" >> "$LOG_FILE" 2>&1
    done
}

run_remote_backup() {
    local dest="$BACKUP_DEST/$TIMESTAMP"
    local prev; prev=$(ls -1dt "$BACKUP_DEST"/[0-9][0-9][0-9][0-9]-* 2>/dev/null | head -1 || true)
    local -a link_args=(); [[ -n "$prev" ]] && link_args=("--link-dest=$prev")
    check_space "$MOUNT_POINT"
    mkdir -p "$dest"
    LOG "Remote snapshot: $(basename "$dest")${prev:+ (hardlinks from $(basename "$prev"))}"
    _rsync_dirs "$dest" "${link_args[@]}"
    prune_snapshots "$BACKUP_DEST" "${REMOTE_BACKUP_KEEP:-10}"
    LOG "Remote backup complete."
}

run_local_backup() {
    [[ "${LOCAL_BACKUP_ENABLED:-false}" == "true" ]] || return 0
    local dest="$LOCAL_BACKUP_DIR/$TIMESTAMP"
    local prev; prev=$(ls -1dt "$LOCAL_BACKUP_DIR"/[0-9][0-9][0-9][0-9]-* 2>/dev/null | head -1 || true)
    local -a link_args=(); [[ -n "$prev" ]] && link_args=("--link-dest=$prev")
    mkdir -p "$LOCAL_BACKUP_DIR"
    check_space "$LOCAL_BACKUP_DIR"
    mkdir -p "$dest"
    LOG "Local snapshot: $(basename "$dest")"
    _rsync_dirs "$dest" "${link_args[@]}"
    chmod -R a-w "$dest" 2>/dev/null || true
    prune_snapshots "$LOCAL_BACKUP_DIR" "${LOCAL_BACKUP_KEEP:-10}"
    LOG "Local snapshot complete."
}

# ── cleanup ───────────────────────────────────────────────────────────────────
_cleanup() {
    local code=$?
    (( code != 0 )) && { LOG "Backup FAILED (exit $code)."; write_status "failed"; }
    mountpoint -q "$MOUNT_POINT" 2>/dev/null && umount "$MOUNT_POINT" || true
    [[ -b "/dev/mapper/$LUKS_MAPPER" ]] && cryptsetup luksClose "$LUKS_MAPPER" || true
    rm -f "$LOCKFILE"
    LOG "Drive locked."
}
trap '_cleanup' EXIT

# ── main ──────────────────────────────────────────────────────────────────────
require_root
acquire_lock
write_status "running" "starting"
LOG "=== Backup started ==="
unlock_drive
mount_drive
run_remote_backup
run_local_backup
write_status "idle"
LOG "=== Backup finished ==="
