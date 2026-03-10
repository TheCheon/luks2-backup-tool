#!/bin/bash
# update.sh — remove old installation before re-running install.sh
# Run as root: sudo ./update.sh
# This is a one-time migration helper. After this, run: sudo ./install.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo ./update.sh" >&2; exit 1
fi

echo "=== luks2-backup-tool cleanup ==="
echo ""

# ── systemd (system-level) ────────────────────────────────────────────────────
echo "[1/6] Stopping and disabling system services..."
for unit in backup.timer backup.service; do
    systemctl stop    "$unit" 2>/dev/null || true
    systemctl disable "$unit" 2>/dev/null || true
done
rm -f /etc/systemd/system/backup.service \
      /etc/systemd/system/backup.timer
systemctl daemon-reload
echo "      Done."

# ── tray (user-level service for all local users) ─────────────────────────────
echo "[2/6] Stopping tray app..."
pkill -f "backup-tray.py" 2>/dev/null || true
for user_home in /home/*/; do
    user=$(basename "$user_home")
    svc="$user_home/.config/systemd/user/backup-tray.service"
    [[ -f "$svc" ]] || continue
    uid=$(id -u "$user" 2>/dev/null) || continue
    sudo -u "$user" systemctl --user stop    backup-tray.service 2>/dev/null || true
    sudo -u "$user" systemctl --user disable backup-tray.service 2>/dev/null || true
    rm -f "$svc"
    echo "      Removed user service for $user"
done
echo "      Done."

# ── desktop entry ─────────────────────────────────────────────────────────────
echo "[3/6] Removing desktop entry..."
rm -f /usr/share/applications/backup.desktop
command -v update-desktop-database &>/dev/null \
    && update-desktop-database /usr/share/applications/ || true
echo "      Done."

# ── installed scripts ─────────────────────────────────────────────────────────
echo "[4/6] Removing installed scripts from /opt/backup/..."
rm -f /opt/backup/backup.sh \
      /opt/backup/backup-manual.sh \
      /opt/backup/backup-tray.py \
      /opt/backup/backup-status.sh \
      /opt/backup/backup-icon.svg \
      /opt/backup/backup-icon-active.svg \
      /opt/backup/README.md \
      /opt/backup/CHANGELOG.md \
      /opt/backup/backup.conf
echo "      Done."

# ── status file ───────────────────────────────────────────────────────────────
echo "[5/6] Resetting status file..."
if [[ -f /var/lib/backup/status.json ]]; then
    echo '{"status":"idle","last_backup":"","last_backup_result":"","current_operation":""}' \
        > /var/lib/backup/status.json
    chmod 644 /var/lib/backup/status.json
fi
echo "      Done."

# ── summary ───────────────────────────────────────────────────────────────────
echo "[6/6] Preserved (not touched):"
echo "      /etc/backup/backup.conf   ← active config"
echo "      /etc/backup/backup.key    ← LUKS keyfile"
[[ "${LOCAL_BACKUP_DIR:-}" ]] \
    && echo "      $LOCAL_BACKUP_DIR   ← local snapshots" || true

echo ""
echo "Cleanup complete. Now run:"
echo "  sudo ./install.sh"
echo ""
