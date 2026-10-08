#!/bin/bash
# Volatile Data Triage Collection - Linux
# Non-destructive | Root recommended | JSON output to ~/Downloads
# Version: 1.0.0
#
# How to Use
# 1. Save as VolatileTriage.sh
# 2. Make executable
# chmod +x VolatileTriage.sh

# 3. Run as root (recommended)
# sudo ./VolatileTriage.sh
# The JSON will be written to:
# ~/Downloads/VolatileTriage_YYYYMMDD_HHMMSS.json

set -o pipefail
SCRIPT_VERSION="1.2.0"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="${HOME}/Downloads"
OUTPUT_FILE="${OUTPUT_DIR}/VolatileTriage_${TIMESTAMP}.json"
TMPDIR=$(mktemp -d /tmp/volatile_triage.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

section() { echo -e "\n[*] $1" >&2; }

if [ "$(id -u)" -ne 0 ]; then
    echo "[!] WARNING: Not running as root. Some data will be incomplete." >&2
fi
mkdir -p "$OUTPUT_DIR"

# ------------------------------------------------------------------
section "Chain of Custody"
python3 -c '
import json, os, socket
from datetime import datetime, timezone
print(json.dumps({
    "ScriptVersion": "'"$SCRIPT_VERSION"'",
    "CollectionTimeUTC": datetime.now(timezone.utc).isoformat(),
    "CollectionTimeLocal": datetime.now().astimezone().isoformat(),
    "Hostname": socket.gethostname(),
    "CollectedBy": os.environ.get("USER") or os.environ.get("LOGNAME") or "unknown",
    "UID": os.getuid(),
    "IsRoot": os.getuid() == 0,
    "Kernel": os.uname().release,
    "OutputFile": "'"$OUTPUT_FILE"'",
    "Notes": "Non-destructive volatile triage. No system state was modified."
}, indent=2))
' > "$TMPDIR/custody.json"

# ------------------------------------------------------------------
section "System Information"
python3 -c '
import json, platform, subprocess
info = {
    "Hostname": platform.node(),
    "Kernel": platform.uname().release,
    "System": platform.system(),
    "Machine": platform.machine(),
}
try:
    with open("/etc/os-release") as f:
        for line in f:
            if line.startswith("PRETTY_NAME="):
                info["Distribution"] = line.split("=",1)[1].strip().strip("\"")
except: pass
try:
    info["Uptime"] = subprocess.getoutput("uptime -p")
except: pass
try:
    with open("/proc/meminfo") as f:
        for line in f:
            if line.startswith("MemTotal:"):
                info["TotalMemoryGB"] = round(int(line.split()[1])/1024/1024, 2)
except: pass
print(json.dumps(info, indent=2))
' > "$TMPDIR/system.json"

# ------------------------------------------------------------------
section "Processes"
ps -eo pid,ppid,user,stat,lstart,etime,pcpu,pmem,rss,vsz,cmd --no-headers 2>/dev/null | python3 -c '
import sys, json
procs = []
for line in sys.stdin:
    parts = line.strip().split(None, 10)
    if len(parts) >= 11:
        procs.append({
            "PID": parts[0], "PPID": parts[1], "User": parts[2],
            "Stat": parts[3], "Start": " ".join(parts[4:9]),
            "Elapsed": parts[9], "CMD": parts[10]
        })
print(json.dumps(procs, indent=2))
' > "$TMPDIR/processes.json"

# ------------------------------------------------------------------
section "Network Connections"
ss -tulnape 2>/dev/null | python3 -c '
import sys, json
conns = []
for line in sys.stdin:
    line = line.strip()
    if not line or line.startswith("Netid") or line.startswith("State"):
        continue
    parts = line.split()
    if len(parts) >= 5:
        conns.append({
            "Netid": parts[0],
            "State": parts[1] if parts[0].startswith("tcp") else "",
            "Local": parts[4],
            "Peer": parts[5] if len(parts) > 5 else "",
            "Process": " ".join(parts[6:]) if len(parts) > 6 else ""
        })
print(json.dumps(conns, indent=2))
' > "$TMPDIR/connections.json"

# ------------------------------------------------------------------
section "ARP / Neighbors"
ip -j neigh 2>/dev/null > "$TMPDIR/neighbors.json" || echo "[]" > "$TMPDIR/neighbors.json"

# ------------------------------------------------------------------
section "Logged-on Users"
who -a 2>/dev/null | python3 -c '
import sys, json
users = []
for line in sys.stdin:
    parts = line.strip().split()
    if len(parts) >= 3:
        users.append({"User": parts[0], "TTY": parts[1], "Info": " ".join(parts[2:])})
print(json.dumps(users, indent=2))
' > "$TMPDIR/loggedon.json"

# ------------------------------------------------------------------
section "Shell History"
python3 -c '
import os, json, glob
histories = {}
candidates = [
    os.path.expanduser("~/.bash_history"),
    os.path.expanduser("~/.zsh_history"),
    "/root/.bash_history",
    "/root/.zsh_history",
]
if os.geteuid() == 0:
    candidates += glob.glob("/home/*/.bash_history") + glob.glob("/home/*/.zsh_history")
for path in candidates:
    if os.path.isfile(path):
        try:
            with open(path, errors="ignore") as f:
                histories[path] = [l.rstrip() for l in f.readlines()[-500:]]
        except: pass
print(json.dumps(histories, indent=2))
' > "$TMPDIR/history.json"

# ------------------------------------------------------------------
section "Clipboard"
CLIP=""
command -v xclip >/dev/null && CLIP=$(xclip -selection clipboard -o 2>/dev/null)
command -v xsel  >/dev/null && CLIP=$(xsel --clipboard --output 2>/dev/null)
command -v wl-paste >/dev/null && CLIP=$(wl-paste 2>/dev/null)
python3 -c 'import json,sys; print(json.dumps(sys.argv[1] or None))' "$CLIP" > "$TMPDIR/clipboard.json"

# ------------------------------------------------------------------
section "DNS"
python3 -c '
import json, subprocess
dns = {}
try:
    with open("/etc/resolv.conf") as f:
        dns["resolv_conf"] = f.read()
except: pass
for cmd in ["resolvectl status", "systemd-resolve --status"]:
    try:
        dns["resolver_status"] = subprocess.getoutput(cmd)
        break
    except: pass
print(json.dumps(dns, indent=2))
' > "$TMPDIR/dns.json"

# ------------------------------------------------------------------
section "Network Interfaces & Routes"
ip -j addr  > "$TMPDIR/interfaces.json" 2>/dev/null || echo "[]" > "$TMPDIR/interfaces.json"
ip -j route > "$TMPDIR/routes.json"     2>/dev/null || echo "[]" > "$TMPDIR/routes.json"

# ------------------------------------------------------------------
section "Kernel Modules"
lsmod 2>/dev/null | python3 -c '
import sys, json
mods = []
next(sys.stdin, None)
for line in sys.stdin:
    p = line.split()
    if len(p) >= 3:
        mods.append({"Module": p[0], "Size": p[1], "UsedBy": p[2], "By": " ".join(p[3:])})
print(json.dumps(mods, indent=2))
' > "$TMPDIR/modules.json"

# ------------------------------------------------------------------
section "Scheduled Tasks"
python3 -c '
import os, json, subprocess, glob
data = {"user_crontabs": {}, "system_cron": [], "systemd_timers": []}
users = ["root"]
if os.path.isdir("/home"):
    users += [d for d in os.listdir("/home") if os.path.isdir("/home/"+d)]
for u in users:
    try:
        out = subprocess.check_output(["crontab","-u",u,"-l"], stderr=subprocess.DEVNULL, text=True)
        data["user_crontabs"][u] = out.splitlines()
    except: pass
for path in ["/etc/crontab"] + glob.glob("/etc/cron.*/*"):
    if os.path.isfile(path):
        try:
            with open(path) as f:
                data["system_cron"].append({path: f.read().splitlines()})
        except: pass
try:
    data["systemd_timers"] = subprocess.getoutput("systemctl list-timers --all --no-pager --no-legend").splitlines()
except: pass
print(json.dumps(data, indent=2))
' > "$TMPDIR/scheduled.json"

# ------------------------------------------------------------------
section "Environment Variables"
env | python3 -c '
import sys, json
print(json.dumps(dict(line.strip().split("=",1) for line in sys.stdin if "=" in line), indent=2))
' > "$TMPDIR/env.json"

# ------------------------------------------------------------------
section "Open Files"
if command -v lsof >/dev/null; then
    lsof -nP 2>/dev/null | head -n 1500 | python3 -c '
import sys, json
print(json.dumps([line.strip() for line in sys.stdin], indent=2))
' > "$TMPDIR/lsof.json"
else
    echo "[]" > "$TMPDIR/lsof.json"
fi

# ------------------------------------------------------------------
section "Writing final JSON"
python3 -c '
import json, os, hashlib
def load(n):
    try:
        with open("'"$TMPDIR"'/" + n) as f:
            return json.load(f)
    except:
        return None
triage = {
    "ChainOfCustody": load("custody.json"),
    "SystemInformation": load("system.json"),
    "Processes": load("processes.json"),
    "NetworkConnections": load("connections.json"),
    "ARP_Neighbors": load("neighbors.json"),
    "LoggedOnUsers": load("loggedon.json"),
    "ShellHistory": load("history.json"),
    "Clipboard": load("clipboard.json"),
    "DNS": load("dns.json"),
    "NetworkInterfaces": load("interfaces.json"),
    "RoutingTable": load("routes.json"),
    "KernelModules": load("modules.json"),
    "ScheduledTasks": load("scheduled.json"),
    "EnvironmentVariables": load("env.json"),
    "OpenFiles": load("lsof.json")
}
with open("'"$OUTPUT_FILE"'", "w") as f:
    json.dump(triage, f, indent=2)
with open("'"$OUTPUT_FILE"'", "rb") as f:
    sha = hashlib.sha256(f.read()).hexdigest()
triage["ChainOfCustody"]["OutputSHA256"] = sha
triage["ChainOfCustody"]["FileSizeBytes"] = os.path.getsize("'"$OUTPUT_FILE"'")
with open("'"$OUTPUT_FILE"'", "w") as f:
    json.dump(triage, f, indent=2)
print("Output file : '"$OUTPUT_FILE"'")
print("SHA-256     :", sha)
print("Size        : %.2f MB" % (os.path.getsize("'"$OUTPUT_FILE"'")/1024/1024))
'

echo ""
echo "Collection complete."
ENDOFSCRIPT
