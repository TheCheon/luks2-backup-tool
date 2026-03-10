# CHANGELOG

All notable changes to this project are listed here, newest first.

---

## 2026-03-10  — Config file + wizard installer + selective backup

(see original CHANGELOG in project root)

---

## [Unreleased]  — Tray icon, incremental snapshots, local read-only backup

### Added
- **`backup-tray.py`** — GTK system tray app (AppIndicator3/AyatanaAppIndicator3); shows
  backup status (idle / syncing / failed), last run time, next scheduled run;
  icon swaps to an orange badge while a backup is active.
- **Run Backup Now** button in tray menu — triggers `pkexec backup-manual.sh` from
  a background thread so the UI stays responsive.
- **`extras/backup-tray.service`** — systemd user service; installed to
  `~/.config/systemd/user/` so the tray auto-starts with the graphical session.
- **`extras/backup-icon-active.svg`** — orange-badge variant of the drive icon shown
  during an active backup.
- **Incremental snapshots with `--link-dest`** — each backup run now creates a
  new timestamped folder (`YYYY-MM-DD_HH-MM-SS`) inside `BACKUP_DEST`; unchanged
  files are hardlinked from the previous snapshot (Time Machine–style). Space used
  equals only the changed files, not a full copy per run.
- **Local read-only snapshots** (`LOCAL_BACKUP_ENABLED`) — same hardlink-based
  snapshots written to `LOCAL_BACKUP_DIR` on the local disk; snapshot is
  `chmod -R a-w` after writing so accidental deletions can't touch it.
- **`/var/lib/backup/status.json`** — written by both backup scripts; tray and
  `backup-status.sh` read it to display current state.
- **`acquire_lock()`** — PID-based lock file prevents concurrent backup runs.
- **`check_space()`** — warns in the log if free space drops below `MIN_FREE_GB`.
- **`prune_snapshots()`** — automatically removes oldest snapshots beyond the
  configured keep count (`REMOTE_BACKUP_KEEP`, `LOCAL_BACKUP_KEEP`).
- **`backup-status.sh`** — CLI quick-status tool; reads `status.json` and queries
  the systemd timer for the next scheduled run.
- **`update.sh`** — one-time migration helper to cleanly remove the prior
  installation before re-running `install.sh`.

### Changed
- `backup.conf` — gains five new settings: `REMOTE_BACKUP_KEEP`, `LOCAL_BACKUP_ENABLED`,
  `LOCAL_BACKUP_DIR`, `LOCAL_BACKUP_KEEP`, `MIN_FREE_GB`.
- `backup.sh` / `backup-manual.sh` — rewritten to use new snapshot architecture;
  `run_backup()` replaced by `run_remote_backup()` + `run_local_backup()` via
  shared `_rsync_dirs()` helper; `cleanup()` replaced by `_cleanup()` EXIT trap
  that writes a failed status on non-zero exit.
- `extras/backup.desktop` — `Exec` changed to launch the tray app instead of
  directly running `backup-manual.sh`.
