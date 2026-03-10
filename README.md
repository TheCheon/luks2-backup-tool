# backup — encrypted home directory backup

Automated + on-demand backup of selected home directories to a LUKS2-encrypted external drive,
with a system tray icon, incremental timestamped snapshots, and optional local read-only copies.

---

## How it works

```
[systemd timer]  ──► backup.sh        ─┐
[tray "Run now"] ──► backup-manual.sh ─┤─► read /etc/backup/backup.conf
                                        ├─► unlock LUKS2 ──► mount
                                        ├─► rsync → timestamped snapshot (--link-dest)
                                        ├─► local read-only snapshot (optional)
                                        ├─► write /var/lib/backup/status.json
                                        └─► umount & lock drive
```

- Only the **folders you list** in `backup.conf` are synced — not your entire home dir.
- **LUKS2** is unlocked with a keyfile at `/etc/backup/backup.key` (root-readable only, 512 random bytes). No password stored in plain text.
- Each backup creates a **timestamped folder** (`YYYY-MM-DD_HH-MM-SS`) and uses rsync `--link-dest` to hardlink unchanged files from the previous run — full history, but only changed files use extra space.
- **Local snapshots** (optional) write the same hardlink-based copies to your local disk, then make them read-only (`chmod -R a-w`), giving you a fast recovery path without needing the drive.
- Old snapshots are **pruned automatically** to a configurable keep count.
- The drive is always re-locked after a run, even on error (bash `trap`).
- The **tray app** shows status, last run time, and next scheduled run; the icon turns orange while a backup is active.

---

## File layout

```
/opt/backup/
  backup.sh                    ← automated backup (systemd)
  backup-manual.sh             ← on-demand backup (tray / terminal)
  backup-tray.py               ← GTK system tray application
  backup-status.sh             ← CLI quick-status tool
  backup-icon.svg              ← tray icon (idle — green)
  backup-icon-active.svg       ← tray icon (running — orange)
  README.md
  CHANGELOG.md

/etc/backup/
  backup.conf                  ← active config (edit this one)
  backup.key                   ← LUKS keyfile (root 400)

/etc/systemd/system/
  backup.service
  backup.timer

~/.config/systemd/user/
  backup-tray.service          ← starts tray on graphical login

/usr/share/applications/
  backup.desktop               ← launches the tray app

/var/lib/backup/
  status.json                  ← live status written by backup scripts

/var/backup/snapshots/         ← local read-only snapshots (if enabled)
/mnt/backup/home-backup/       ← remote snapshots on the encrypted drive
```

---

## Setup

### Prerequisites

```bash
# Arch
sudo pacman -S cryptsetup rsync libnotify python-gobject libayatana-appindicator

# Debian/Ubuntu
sudo apt install cryptsetup rsync libnotify-bin python3-gi \
                 gir1.2-ayatana-appindicator3-0.1
```

> **GNOME users:** also install the [AppIndicator extension](https://extensions.gnome.org/extension/615/appindicator-support/) so the tray icon appears in the top bar.

### Run the install wizard

```bash
cd /path/to/this/project
sudo ./install.sh
```

The wizard will:
1. Auto-detect LUKS partitions and let you pick your backup drive
2. Ask which user's home folder to back up
3. List available folders and let you choose a subset
4. Generate a keyfile (or detect an existing one)
5. Enroll the keyfile into the drive's LUKS headers (you enter your passphrase once)
6. Ask whether to enable local read-only snapshots and where to store them
7. Write `/etc/backup/backup.conf` with all your choices
8. Install all scripts, systemd units, and the desktop entry
9. Install and enable the tray app user service

### Migrating from an older version

If you have the old version installed, run the cleanup helper first:

```bash
sudo ./update.sh   # removes old /opt/backup install, stops services
sudo ./install.sh  # re-install fresh
```

---

## Tray application

The tray icon sits in your system tray at all times:

| State | Icon | Menu shows |
|---|---|---|
| Idle | green drive | Last run time + result, next scheduled run |
| Running | orange badge | Current folder being synced |
| Failed | green drive | Last run time with ✗ badge |

**Run Backup Now** in the menu triggers `backup-manual.sh` via `pkexec` (asks for your sudo password once).

To start the tray manually:
```bash
python3 /opt/backup/backup-tray.py
```

The user systemd service starts it automatically on login:
```bash
systemctl --user status backup-tray.service
```

---

## Snapshots

Each backup run produces a new folder named by timestamp:

```
/mnt/backup/home-backup/
  2026-03-10_02-30-01/
    Documents/
    Pictures/
    .config/
  2026-03-09_02-30-00/      ← unchanged files are hardlinks to the run above
  2026-03-08_14-15-33/
```

Only files that actually changed consume new disk space. Snapshots older than `REMOTE_BACKUP_KEEP` (default: 10) are removed automatically.

Local snapshots work the same way and are stored at `LOCAL_BACKUP_DIR` (default: `/var/backup/snapshots/`). After each write they are made read-only, so accidental deletions can't touch them.

---

## Changing what gets backed up

Edit `/etc/backup/backup.conf`:

```bash
sudo nano /etc/backup/backup.conf
```

**Select folders:**
```bash
BACKUP_DIRS=(
    "Documents"
    "Pictures"
    ".config"
    ".ssh"
    "my-extra-folder"   # ← add this
)
```

**Adjust snapshot retention:**
```bash
REMOTE_BACKUP_KEEP=10   # snapshots kept on the encrypted drive
LOCAL_BACKUP_KEEP=10    # snapshots kept locally
MIN_FREE_GB=5           # warn in log if less than this remains
```

**Toggle local snapshots:**
```bash
LOCAL_BACKUP_ENABLED=true
LOCAL_BACKUP_DIR="/var/backup/snapshots"
```

No restart needed — changes are picked up on the next run.

---

## Usage

### Tray
Click the drive icon in your system tray → **⟳ Run Backup Now**.

### Terminal (on-demand)
```bash
sudo /opt/backup/backup-manual.sh
```

### CLI status
```bash
/opt/backup/backup-status.sh
```
Shows current state, last backup time, and next scheduled run.

### Automatic
The timer fires:
- **3 minutes after every boot**
- **Daily at 02:30** (`Persistent=true` catches up if the PC was off)

```bash
systemctl status backup.timer
systemctl list-timers backup.timer

# Trigger the automated version immediately (no notifications)
sudo systemctl start backup.service
```

---

## Logs

```bash
# Live tail
tail -f /var/log/backup.log

# systemd journal (automated runs)
journalctl -u backup.service -f
journalctl -u backup.service -n 100

# Quick status summary
/opt/backup/backup-status.sh
```

---

## Error reference

### `ERROR: config file /etc/backup/backup.conf not found`
The install wizard hasn't been run yet, or `/etc/backup/` was deleted. Run `sudo ./install.sh`.

### `ERROR: LUKS device … not found. Is the drive plugged in?`
The block device in `LUKS_DEVICE` doesn't exist. Either:
- Drive not connected — plug it in.
- Device path shifted — the `by-uuid` path set by `install.sh` is stable and should not break.

### `ERROR: Keyfile /etc/backup/backup.key not found`
Keyfile was not generated. Run `sudo ./install.sh` — it skips steps already done.

### `Failed to open … No key available with this passphrase`
Keyfile exists but isn't enrolled in this drive's LUKS slots:
```bash
sudo cryptsetup luksAddKey /dev/disk/by-uuid/YOUR-UUID /etc/backup/backup.key
```

### `mount: /mnt/backup: can't read superblock`
Filesystem unclean. Run:
```bash
sudo cryptsetup luksOpen --key-file=/etc/backup/backup.key /dev/disk/by-uuid/YOUR-UUID backup_drive
sudo fsck /dev/mapper/backup_drive
```

### `rsync: [Errno 28] No space left on device`
Backup drive is full. Lower `REMOTE_BACKUP_KEEP` in the config to prune more aggressively, or remove data from the drive manually.

### `rsync: read error: Connection reset by peer`
Drive disconnected mid-sync. Plug back in and re-run — rsync resumes from what it can.

### Timer doesn't run on boot
1. `systemctl is-enabled backup.timer` → should say `enabled`
2. `LUKS_DEVICE` in config must match `lsblk -f` output
3. `ConditionPathExists` in `backup.service` must reference the same device
4. `journalctl -u backup.service -b` for the current boot's errors

### Tray icon doesn't appear
- **GNOME:** install the [AppIndicator extension](https://extensions.gnome.org/extension/615/appindicator-support/)
- **Missing library (Arch):** `sudo pacman -S libayatana-appindicator`
- **Missing library (Debian):** `sudo apt install gir1.2-ayatana-appindicator3-0.1`
- Check the service: `systemctl --user status backup-tray.service`
- Run manually to see errors: `python3 /opt/backup/backup-tray.py`

### Desktop icon does nothing
- Ensure `polkit` is installed: `sudo pacman -S polkit` or `sudo apt install policykit-1`
- Confirm scripts are executable: `ls -la /opt/backup/`
- Test from terminal: `sudo /opt/backup/backup-manual.sh`

### No desktop notification
`libnotify` must be installed and you must be logged in graphically. The backup still runs and logs correctly without it.

### `Backup already running (PID …). Aborting.`
Another backup process is active. Wait for it to finish, or if it's stale: `sudo rm /var/run/backup.lock`

