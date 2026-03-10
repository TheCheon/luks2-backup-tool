#!/usr/bin/env python3
"""
backup-tray — system tray icon for luks2-backup-tool

Shows backup status, last/next run, lets you trigger a manual backup.
Requires: python3-gi
AppIndicator (one of):
  Arch:   libayatana-appindicator  (+ python-gobject)
  Debian: gir1.2-ayatana-appindicator3-0.1
  GNOME:  gnome-shell-extension-appindicator (AUR or extensions.gnome.org)
"""

import datetime
import fcntl
import json
import os
import shutil
import subprocess
import sys
import threading

# ── single-instance lock ──────────────────────────────────────────────────────
_LOCK_PATH = "/tmp/backup-tray.lock"
try:
    _lockfile = open(_LOCK_PATH, "w")
    fcntl.flock(_lockfile, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    print("backup-tray is already running.", file=sys.stderr)
    sys.exit(0)

# ── GTK + AppIndicator ────────────────────────────────────────────────────────
import gi
gi.require_version("Gtk", "3.0")

AppIndicator3 = None
for _lib in ("AyatanaAppIndicator3", "AppIndicator3"):
    try:
        gi.require_version(_lib, "0.1")
        from gi.repository import AyatanaAppIndicator3 as AppIndicator3
        break
    except Exception:
        AppIndicator3 = None

from gi.repository import Gtk, GLib

# ── paths ─────────────────────────────────────────────────────────────────────
STATUS_FILE  = "/var/lib/backup/status.json"
LOG_FILE     = "/var/log/backup.log"
ICON_IDLE    = "/opt/backup/backup-icon.svg"
ICON_RUNNING = "/opt/backup/backup-icon-active.svg"
BACKUP_CMD   = "/opt/backup/backup-manual.sh"
POLL_SECS    = 8

# ── helpers ───────────────────────────────────────────────────────────────────

def read_status() -> dict:
    try:
        with open(STATUS_FILE) as f:
            return json.load(f)
    except Exception:
        return {}


def get_next_backup() -> "datetime.datetime | None":
    """Query systemd for the next timer fire time."""
    try:
        raw = subprocess.run(
            ["systemctl", "show", "backup.timer",
             "--property=NextElapseUSecRealtime"],
            capture_output=True, text=True, timeout=3
        ).stdout.strip().split("=", 1)[-1].strip()

        if not raw or raw in ("0", "n/a", "[not set]"):
            return None

        # systemd may return "Weekday YYYY-MM-DD HH:MM:SS TZ"
        parts = raw.split()
        if len(parts) >= 3:
            return datetime.datetime.strptime(
                f"{parts[1]} {parts[2]}", "%Y-%m-%d %H:%M:%S"
            )
        # Older systemd: microseconds since epoch
        if raw.isdigit():
            return datetime.datetime.fromtimestamp(int(raw) / 1_000_000)
    except Exception:
        pass
    return None


def fmt_dt(val) -> str:
    if not val:
        return "—"
    if isinstance(val, str):
        try:
            val = datetime.datetime.fromisoformat(val)
        except Exception:
            return val
    try:
        now = datetime.datetime.now()
        if val.date() == now.date():
            return f"Today  {val.strftime('%H:%M')}"
        if (val.date() - now.date()).days == 1:
            return f"Tomorrow  {val.strftime('%H:%M')}"
        return val.strftime("%b %d  %H:%M")
    except Exception:
        return str(val)


def open_log_file() -> None:
    for viewer in ("xdg-open", "gnome-text-editor", "gedit",
                   "mousepad", "kate", "xed"):
        if shutil.which(viewer):
            subprocess.Popen([viewer, LOG_FILE])
            return
    # last resort: terminal tail
    for term in ("xterm", "kitty", "alacritty", "gnome-terminal"):
        if shutil.which(term):
            subprocess.Popen([term, "-e", f"tail -n 80 -f {LOG_FILE}"])
            return


# ── tray ─────────────────────────────────────────────────────────────────────

class BackupTray:
    def __init__(self):
        self._busy = False
        self._menu = self._build_menu()
        icon = ICON_IDLE if os.path.exists(ICON_IDLE) else "drive-harddisk"

        if AppIndicator3:
            self._ind = AppIndicator3.Indicator.new(
                "luks2-backup", icon,
                AppIndicator3.IndicatorCategory.APPLICATION_STATUS,
            )
            self._ind.set_status(AppIndicator3.IndicatorStatus.ACTIVE)
            self._ind.set_menu(self._menu)

            def _set_icon(path):
                p = path if os.path.exists(path) else "drive-harddisk"
                self._ind.set_icon_full(p, "Backup")
        else:
            # Fallback: legacy StatusIcon
            self._si = Gtk.StatusIcon()
            self._si.set_from_file(icon) if os.path.exists(icon) \
                else self._si.set_from_icon_name("drive-harddisk")
            self._si.set_tooltip_text("Backup")
            self._si.connect("popup-menu", self._on_popup)

            def _set_icon(path):
                if os.path.exists(path):
                    self._si.set_from_file(path)
                else:
                    self._si.set_from_icon_name("drive-harddisk")

        self._set_icon = _set_icon
        GLib.timeout_add_seconds(POLL_SECS, self._refresh)
        self._refresh()

    # ── menu construction ────────────────────────────────────────────────────

    def _build_menu(self) -> Gtk.Menu:
        menu = Gtk.Menu()

        self._lbl_status = self._add_static(menu, "—")
        self._lbl_last   = self._add_static(menu, "Last:  —")
        self._lbl_next   = self._add_static(menu, "Next:  —")

        menu.append(Gtk.SeparatorMenuItem())

        self._btn_run = Gtk.MenuItem(label="⟳  Run Backup Now")
        self._btn_run.connect("activate", self._on_run_backup)
        menu.append(self._btn_run)

        menu.append(Gtk.SeparatorMenuItem())

        item_log = Gtk.MenuItem(label="📄  Open Log")
        item_log.connect("activate", lambda _: open_log_file())
        menu.append(item_log)

        menu.append(Gtk.SeparatorMenuItem())

        item_quit = Gtk.MenuItem(label="Quit")
        item_quit.connect("activate", lambda _: Gtk.main_quit())
        menu.append(item_quit)

        menu.show_all()
        return menu

    @staticmethod
    def _add_static(menu: Gtk.Menu, label: str) -> Gtk.MenuItem:
        item = Gtk.MenuItem(label=label)
        item.set_sensitive(False)
        menu.append(item)
        return item

    def _on_popup(self, _icon, button, time):
        self._menu.popup(None, None, None, None, button, time)

    # ── status refresh ───────────────────────────────────────────────────────

    def _refresh(self) -> bool:
        status = read_status()
        state  = status.get("status", "unknown")
        last   = status.get("last_backup", "")
        result = status.get("last_backup_result", "")
        op     = status.get("current_operation", "")
        nxt    = get_next_backup()

        if state == "running":
            lbl = f"⟳  Syncing  {op}" if op else "⟳  Syncing…"
            self._set_icon(ICON_RUNNING)
            self._btn_run.set_sensitive(False)
        elif state == "failed":
            lbl = "✗  Last backup failed"
            self._set_icon(ICON_IDLE)
            self._btn_run.set_sensitive(True)
        else:
            lbl = "✓  Idle"
            self._set_icon(ICON_IDLE)
            self._btn_run.set_sensitive(not self._busy)

        self._lbl_status.set_label(lbl)

        last_str = fmt_dt(last) if last else "—"
        suffix = "  ✗" if result == "failed" else ("  ✓" if result == "success" else "")
        self._lbl_last.set_label(f"Last:  {last_str}{suffix}")
        self._lbl_next.set_label(f"Next:  {fmt_dt(nxt)}")

        return True  # keep GLib timer alive

    # ── backup trigger ───────────────────────────────────────────────────────

    def _on_run_backup(self, _):
        self._busy = True
        self._btn_run.set_sensitive(False)
        self._lbl_status.set_label("⟳  Starting…")
        self._set_icon(ICON_RUNNING)
        threading.Thread(target=self._do_run, daemon=True).start()

    def _do_run(self):
        try:
            subprocess.run(["pkexec", BACKUP_CMD], check=False)
        except Exception as exc:
            print(f"[backup-tray] run error: {exc}", file=sys.stderr)
        finally:
            self._busy = False
            GLib.idle_add(self._refresh)


# ── main ─────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    if not AppIndicator3:
        print(
            "[backup-tray] WARNING: AppIndicator3 not found; using deprecated "
            "StatusIcon fallback.\n"
            "  Arch:   pacman -S libayatana-appindicator\n"
            "  Ubuntu: apt install gir1.2-ayatana-appindicator3-0.1\n"
            "  GNOME:  install gnome-shell-extension-appindicator",
            file=sys.stderr,
        )

    BackupTray()

    try:
        Gtk.main()
    finally:
        try:
            fcntl.flock(_lockfile, fcntl.LOCK_UN)
            _lockfile.close()
            os.unlink(_LOCK_PATH)
        except Exception:
            pass
