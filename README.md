# backup — encrypted home directory backup

Automated + on-demand backup of selected home directories to a LUKS2-encrypted external drive.
Runs via a systemd timer (on boot + daily) and can be triggered manually via a desktop shortcut or terminal.

---

## How it works

```
[systemd timer] ──► backup.sh        ──► read /etc/backup/backup.conf
[desktop icon]  ──► backup-manual.sh ──► open LUKS2 ──► mount ──► rsync selected dirs ──► umount & lock
```

- Only the **folders you list** in `backup.conf` are synced — not your entire home dir.
- **LUKS2** is unlocked with a keyfile at `/etc/backup/backup.key` (root-readable only, 512 random bytes). No password stored anywhere in plain text.
- **rsync** syncs incrementally — only changed files transfer each run.
- The drive is always re-locked after a run, even on error (bash `trap`).
- All output goes to `/var/log/backup.log` and the systemd journal.

---

## File layout

```
/opt/backup/                   ← project root (all editable files)
  backup.sh                    ← automated backup (systemd)
  backup-manual.sh             ← on-demand backup (desktop / terminal)
  backup.conf                  ← template config (reference copy)
  backup-icon.svg
  backup.desktop               ← template (installed to /usr/share/applications/)
  README.md
  CHANGELOG.md

/etc/backup/
  backup.conf                  ← active config (edit this one)
  backup.key                   ← LUKS keyfile (root 400)

/etc/systemd/system/
  backup.service
  backup.timer

/usr/share/applications/
  backup.desktop
```

---

## Setup

### Prerequisites

```bash
# Arch
sudo pacman -S cryptsetup rsync libnotify python

# Debian/Ubuntu
sudo apt install cryptsetup rsync libnotify-bin python3
```

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
6. Write `/etc/backup/backup.conf` with your choices
7. Install all scripts, systemd units, and the desktop entry
8. Enable and start the timer

---

## Changing what gets backed up

Edit `/etc/backup/backup.conf`:

```bash
sudo nano /etc/backup/backup.conf
```

Add or remove entries from `BACKUP_DIRS`. Entries are relative to `/home/<SOURCE_USER>`:

```bash
BACKUP_DIRS=(
    "Documents"
    "Pictures"
    ".config"
    ".ssh"
    "my-extra-folder"   # ← add this
)
```

No restart needed — the next backup run will pick up the change automatically.

---

## Usage

### Manual — from the desktop

Click **Run Backup Now** in your app launcher. pkexec asks for your sudo password once, then runs silently with a desktop notification at start and finish.

### Manual — from the terminal

```bash
sudo /opt/backup/backup-manual.sh
```

### Automatic

The timer fires:
- **3 minutes after every boot**
- **Daily at 02:30** (`Persistent=true` catches up if the PC was off)

```bash
# Status
systemctl status backup.timer
systemctl list-timers backup.timer

# Run the automated version immediately (no notifications)
sudo systemctl start backup.service
```

---

## Logs

```bash
# Live (manual runs + automated)
tail -f /var/log/backup.log

# systemd journal (automated runs only)
journalctl -u backup.service -f
journalctl -u backup.service -n 100
```

---

## Error reference

### `ERROR: config file /etc/backup/backup.conf not found`
The install wizard hasn't been run yet, or `/etc/backup/` was deleted. Run `sudo ./install.sh`.

### `ERROR: LUKS device … not found. Is the drive plugged in?`
The block device in `LUKS_DEVICE` doesn't exist. Either:
- Drive not connected — plug it in.
- Device path shifted (e.g. `/dev/sda` → `/dev/sdb`) — the by-uuid path set by `install.sh` is stable and should not break.

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
Backup drive is full. Remove old data from the drive or slim down `BACKUP_DIRS` in the config.

### `rsync: read error: Connection reset by peer`
Drive disconnected mid-sync. Plug back in and re-run — rsync resumes from what it can.

### Timer doesn't run on boot
1. `systemctl is-enabled backup.timer` → should say `enabled`
2. `LUKS_DEVICE` in config must match `lsblk -f` output
3. `ConditionPathExists` in `backup.service` must reference the same device
4. `journalctl -u backup.service -b` for the current boot's errors

### Desktop icon does nothing
- Ensure `polkit` is installed: `sudo pacman -S polkit` or `sudo apt install policykit-1`
- Confirm script is executable: `ls -la /opt/backup/backup-manual.sh`
- Test from terminal: `sudo /opt/backup/backup-manual.sh`

### No desktop notification
`libnotify` must be installed and you must be logged in graphically. The backup still runs and logs correctly without it.

