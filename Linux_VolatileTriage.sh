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
SCRIPT_VERSION="1.0.0"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="${HOME}/Downloads"
OUTPUT_FILE="${OUTPUT_DIR}/VolatileTriage_${TIMESTAMP}.json"
TMPDIR=$(mktemp -d /tmp/volatile_triage.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------
is_root() { [ "$(id -u)" -eq 0 ]; }

json_escape() {
    # Simple escape for strings that will go into JSON
    python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || \
    sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r/\\r/g; s/\n/\\n/g'
}

section() { echo -e "\n[*] $1" >&2; }

# ------------------------------------------------------------------
# Privilege check
# ------------------------------------------------------------------
if ! is_root; then
    echo "[!] WARNING: Not running as root. Some data (other users' history, full process details, etc.) will be incomplete." >&2
fi

mkdir -p "$OUTPUT_DIR"

# ------------------------------------------------------------------
# 1. Chain of Custody
# ------------------------------------------------------------------
section "Chain of Custody"
COLLECTED_BY=$(whoami)
HOSTNAME=$(hostname)
DOMAIN=$(hostname -d 2>/dev/null || echo "")
KERNEL=$(uname -r)
DISTRO=$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"' || uname -s)

cat > "$TMPDIR/custody.json" <<EOF
{
  "ScriptVersion": "$SCRIPT_VERSION",
  "CollectionTimeUTC": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "CollectionTimeLocal": "$(date +%Y-%m-%dT%H:%M:%S%z)",
  "Hostname": "$HOSTNAME",
  "Domain": "$DOMAIN",
  "CollectedBy": "$COLLECTED_BY",
  "UID": "$(id -u)",
  "IsRoot": $(is_root && echo true || echo false),
  "Kernel": "$KERNEL",
  "Distribution": "$DISTRO",
  "OutputFile": "$OUTPUT_FILE",
  "Notes": "Non-destructive volatile triage. No system state was modified."
}
EOF

# ------------------------------------------------------------------
# 2. System Information
# ------------------------------------------------------------------
section "System Information"
UPTIME=$(uptime -p 2>/dev/null || uptime)
LAST_BOOT=$(who -b 2>/dev/null | awk '{print $3,$4}')
MEM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{printf "%.2f", $2/1024/1024}')
CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | xargs)
CPU_CORES=$(nproc)

cat > "$TMPDIR/system.json" <<EOF
{
  "Hostname": "$HOSTNAME",
  "Kernel": "$(uname -a)",
  "Distribution": "$DISTRO",
  "Architecture": "$(uname -m)",
  "Uptime": "$UPTIME",
  "LastBoot": "$LAST_BOOT",
  "TotalMemoryGB": $MEM_TOTAL,
  "CPUModel": "$CPU_MODEL",
  "CPUCores": $CPU_CORES,
  "Timezone": "$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo unknown)"
}
EOF

# ------------------------------------------------------------------
# 3. Running Processes
# ------------------------------------------------------------------
section "Processes"
ps -eo pid,ppid,user,stat,lstart,etime,pcpu,pmem,rss,vsz,cmd --no-headers 2>/dev/null | \
python3 -c '
import sys, json
procs = []
for line in sys.stdin:
    parts = line.strip().split(None, 10)
    if len(parts) < 11: continue
    procs.append({
        "PID": int(parts[0]),
        "PPID": int(parts[1]),
        "User": parts[2],
        "Stat": parts[3],
        "Start": " ".join(parts[4:9]),
        "Elapsed": parts[9],
        "CPU": parts[10] if len(parts)>10 else "",
        "MEM": parts[11] if len(parts)>11 else "",
        "RSS": parts[12] if len(parts)>12 else "",
        "VSZ": parts[13] if len(parts)>13 else "",
        "CMD": parts[14] if len(parts)>14 else " ".join(parts[10:])
    })
print(json.dumps(procs, indent=2))
' > "$TMPDIR/processes.json" 2>/dev/null || echo "[]" > "$TMPDIR/processes.json"

# ------------------------------------------------------------------
# 4. Network Connections (TCP/UDP + listening)
# ------------------------------------------------------------------
section "Network Connections"
ss -tulnape 2>/dev/null | python3 -c '
import sys, json, re
conns = []
for line in sys.stdin:
    line = line.strip()
    if not line or line.startswith("Netid") or line.startswith("State"): continue
    parts = line.split()
    if len(parts) < 5: continue
    entry = {
        "Netid": parts[0],
        "State": parts[1] if parts[0] in ("tcp","tcp6") else "",
        "RecvQ": parts[2] if len(parts)>2 else "",
        "SendQ": parts[3] if len(parts)>3 else "",
        "Local": parts[4] if len(parts)>4 else "",
        "Peer": parts[5] if len(parts)>5 else "",
        "Process": " ".join(parts[6:]) if len(parts)>6 else ""
    }
    conns.append(entry)
print(json.dumps(conns, indent=2))
' > "$TMPDIR/connections.json" 2>/dev/null || echo "[]" > "$TMPDIR/connections.json"

# ------------------------------------------------------------------
# 5. ARP / Neighbor Table
# ------------------------------------------------------------------
section "ARP / Neighbors"
ip -j neigh 2>/dev/null > "$TMPDIR/neighbors.json" || \
ip neigh 2>/dev/null | python3 -c '
import sys, json
neigh = []
for line in sys.stdin:
    parts = line.strip().split()
    if len(parts) >= 5:
        neigh.append({"IP": parts[0], "Dev": parts[2], "LLADDR": parts[4] if "lladdr" in line else "", "State": parts[-1]})
print(json.dumps(neigh, indent=2))
' > "$TMPDIR/neighbors.json" 2>/dev/null || echo "[]" > "$TMPDIR/neighbors.json"

# ------------------------------------------------------------------
# 6. Logged-on Users / Sessions
# ------------------------------------------------------------------
section "Logged-on Users"
who -a 2>/dev/null | python3 -c '
import sys, json
users = []
for line in sys.stdin:
    parts = line.strip().split()
    if len(parts) >= 5:
        users.append({
            "User": parts[0],
            "TTY": parts[1],
            "Date": " ".join(parts[2:5]) if len(parts)>4 else "",
            "From": parts[5] if len(parts)>5 else "",
            "Idle": parts[6] if len(parts)>6 else "",
            "PID": parts[7] if len(parts)>7 else ""
        })
print(json.dumps(users, indent=2))
' > "$TMPDIR/loggedon.json" 2>/dev/null || echo "[]" > "$TMPDIR/loggedon.json"

# ------------------------------------------------------------------
# 7. Shell History (current user + others if root)
# ------------------------------------------------------------------
section "Shell History"
python3 - <<'PY' > "$TMPDIR/history.json"
import os, json, glob
histories = {}
home = os.path.expanduser("~")
candidates = [
    os.path.join(home, ".bash_history"),
    os.path.join(home, ".zsh_history"),
    os.path.join(home, ".history"),
    os.path.join(home, ".sh_history"),
]
if os.geteuid() == 0:
    for d in glob.glob("/home/*") + ["/root"]:
        candidates += [
            os.path.join(d, ".bash_history"),
            os.path.join(d, ".zsh_history"),
        ]
for path in candidates:
    if os.path.isfile(path):
        try:
            with open(path, "r", errors="ignore") as f:
                lines = f.readlines()[-500:]   # last 500 entries
            histories[path] = [l.rstrip("\n") for l in lines]
        except Exception:
            pass
print(json.dumps(histories, indent=2))
PY

# ------------------------------------------------------------------
# 8. Clipboard (if GUI tools present)
# ------------------------------------------------------------------
section "Clipboard"
CLIP=""
if command -v xclip >/dev/null 2>&1; then
    CLIP=$(xclip -selection clipboard -o 2>/dev/null || true)
elif command -v xsel >/dev/null 2>&1; then
    CLIP=$(xsel --clipboard --output 2>/dev/null || true)
elif command -v wl-paste >/dev/null 2>&1; then
    CLIP=$(wl-paste 2>/dev/null || true)
fi
python3 -c "import json,sys; print(json.dumps(sys.argv[1] if sys.argv[1] else None))" "$CLIP" > "$TMPDIR/clipboard.json"

# ------------------------------------------------------------------
# 9. DNS / Resolver
# ------------------------------------------------------------------
section "DNS"
{
    echo "{"
    echo "\"resolv_conf\": $(cat /etc/resolv.conf 2>/dev/null | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'),"
    if command -v resolvectl >/dev/null 2>&1; then
        echo "\"resolvectl\": $(resolvectl status 2>/dev/null | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')"
    elif command -v systemd-resolve >/dev/null 2>&1; then
        echo "\"systemd_resolve\": $(systemd-resolve --status 2>/dev/null | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')"
    else
        echo "\"resolvectl\": null"
    fi
    echo "}"
} > "$TMPDIR/dns.json"

# ------------------------------------------------------------------
# 10. Network Interfaces + Routing Table
# ------------------------------------------------------------------
section "Network Interfaces & Routes"
ip -j addr 2>/dev/null > "$TMPDIR/interfaces.json" || \
ip addr 2>/dev/null | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' > "$TMPDIR/interfaces.json"

ip -j route 2>/dev/null > "$TMPDIR/routes.json" || \
ip route 2>/dev/null | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' > "$TMPDIR/routes.json"

ip -j -6 route 2>/dev/null > "$TMPDIR/routes6.json" 2>/dev/null || echo "[]" > "$TMPDIR/routes6.json"

# ------------------------------------------------------------------
# 11. Loaded Kernel Modules
# ------------------------------------------------------------------
section "Kernel Modules"
lsmod 2>/dev/null | python3 -c '
import sys, json
mods = []
next(sys.stdin)  # skip header
for line in sys.stdin:
    parts = line.split()
    if len(parts) >= 3:
        mods.append({"Module": parts[0], "Size": parts[1], "UsedBy": parts[2], "By": " ".join(parts[3:]) if len(parts)>3 else ""})
print(json.dumps(mods, indent=2))
' > "$TMPDIR/modules.json" 2>/dev/null || echo "[]" > "$TMPDIR/modules.json"

# ------------------------------------------------------------------
# 12. Scheduled Tasks (cron + systemd timers)
# ------------------------------------------------------------------
section "Scheduled Tasks"
python3 - <<'PY' > "$TMPDIR/scheduled.json"
import os, json, subprocess, glob
data = {"user_crontabs": {}, "system_cron": {}, "systemd_timers": []}

# User crontabs
users = ["root"]
if os.path.isdir("/home"):
    users += [d for d in os.listdir("/home") if os.path.isdir(f"/home/{d}")]
for u in users:
    try:
        out = subprocess.check_output(["crontab", "-u", u, "-l"], stderr=subprocess.DEVNULL, text=True)
        data["user_crontabs"][u] = out.splitlines()
    except Exception:
        pass

# System cron directories
for path in ["/etc/crontab"] + glob.glob("/etc/cron.*/*"):
    if os.path.isfile(path):
        try:
            with open(path) as f:
                data["system_cron"][path] = f.read().splitlines()
        except Exception:
            pass

# systemd timers
try:
    out = subprocess.check_output(["systemctl", "list-timers", "--all", "--no-pager", "--no-legend"], text=True)
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 4:
            data["systemd_timers"].append({
                "Next": " ".join(parts[0:2]),
                "Left": parts[2],
                "Last": " ".join(parts[3:5]) if len(parts)>4 else "",
                "Unit": parts[-1]
            })
except Exception:
    pass

print(json.dumps(data, indent=2))
PY

# ------------------------------------------------------------------
# 13. Environment Variables
# ------------------------------------------------------------------
section "Environment Variables"
env | python3 -c '
import sys, json
env = {}
for line in sys.stdin:
    if "=" in line:
        k,v = line.strip().split("=",1)
        env[k] = v
print(json.dumps(env, indent=2))
' > "$TMPDIR/env.json"

# ------------------------------------------------------------------
# 14. Open Files / Handles (limited)
# ------------------------------------------------------------------
section "Open Files (lsof summary)"
if command -v lsof >/dev/null 2>&1; then
    lsof -nP 2>/dev/null | head -n 2000 | python3 -c '
import sys, json
files = []
header = next(sys.stdin, "").split()
for line in sys.stdin:
    parts = line.split(None, len(header)-1)
    if len(parts) >= 9:
        files.append(dict(zip(header, parts)))
print(json.dumps(files[:1500], indent=2))  # hard limit
' > "$TMPDIR/lsof.json" 2>/dev/null || echo "[]" > "$TMPDIR/lsof.json"
else
    echo "[]" > "$TMPDIR/lsof.json"
fi

# ------------------------------------------------------------------
# Assemble final JSON
# ------------------------------------------------------------------
section "Writing final JSON"
python3 - <<PY
import json, os

def load(name):
    path = os.path.join("$TMPDIR", name)
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
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
    "RoutingTableIPv6": load("routes6.json"),
    "KernelModules": load("modules.json"),
    "ScheduledTasks": load("scheduled.json"),
    "EnvironmentVariables": load("env.json"),
    "OpenFiles": load("lsof.json")
}

with open("$OUTPUT_FILE", "w") as f:
    json.dump(triage, f, indent=2)

# Add SHA-256 to custody and rewrite
import hashlib
with open("$OUTPUT_FILE", "rb") as f:
    sha = hashlib.sha256(f.read()).hexdigest()

triage["ChainOfCustody"]["OutputSHA256"] = sha
triage["ChainOfCustody"]["FileSizeBytes"] = os.path.getsize("$OUTPUT_FILE")

with open("$OUTPUT_FILE", "w") as f:
    json.dump(triage, f, indent=2)

print(f"Output file : $OUTPUT_FILE")
print(f"SHA-256     : {sha}")
print(f"Size        : {os.path.getsize('$OUTPUT_FILE') / 1024 / 1024:.2f} MB")
PY

echo ""
echo "Collection complete."
