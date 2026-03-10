#!/bin/bash
# backup-status.sh — quick CLI status for luks2-backup-tool
STATUS_FILE="/var/lib/backup/status.json"
TIMER_UNIT="backup.timer"

if [[ ! -f "$STATUS_FILE" ]]; then
    echo "No status file found at $STATUS_FILE."
    echo "Has install.sh been run yet?"
    exit 1
fi

python3 - <<'PY'
import json, datetime, subprocess, sys

f = "/var/lib/backup/status.json"
d = json.load(open(f))

status = d.get("status", "unknown")
last   = d.get("last_backup", "")
result = d.get("last_backup_result", "")
op     = d.get("current_operation", "")

icons = {"idle": "✓", "running": "⟳", "failed": "✗"}
icon  = icons.get(status, "?")

print(f"{icon}  Status      : {status.upper()}")
if op:
    print(f"   Operation   : {op}")

if last:
    try:
        dt   = datetime.datetime.fromisoformat(last)
        diff = datetime.datetime.now() - dt
        h, r = divmod(int(diff.total_seconds()), 3600)
        m    = r // 60
        ago  = f"{h}h {m}m ago" if h else f"{m}m ago"
        mark = " ✗" if result == "failed" else (" ✓" if result == "success" else "")
        print(f"   Last backup : {dt.strftime('%Y-%m-%d %H:%M')}{mark}  ({ago})")
    except Exception:
        print(f"   Last backup : {last} [{result}]")
else:
    print("   Last backup : —  (never)")

# Next timer fire
try:
    raw = subprocess.run(
        ["systemctl", "show", "backup.timer",
         "--property=NextElapseUSecRealtime"],
        capture_output=True, text=True, timeout=3
    ).stdout.strip().split("=", 1)[-1].strip()
    parts = raw.split()
    if len(parts) >= 3:
        nxt = datetime.datetime.strptime(f"{parts[1]} {parts[2]}", "%Y-%m-%d %H:%M:%S")
        diff = nxt - datetime.datetime.now()
        total_s = int(diff.total_seconds())
        if total_s > 0:
            h, r = divmod(total_s, 3600)
            m = r // 60
            in_str = f"in {h}h {m}m" if h else f"in {m}m"
            print(f"   Next backup : {nxt.strftime('%Y-%m-%d %H:%M')}  ({in_str})")
        else:
            print(f"   Next backup : pending")
    else:
        print("   Next backup : unknown (timer not active?)")
except Exception:
    print("   Next backup : (could not read timer)")
PY
