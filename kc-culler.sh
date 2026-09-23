#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# kc-culler — Kallichore kernel session watchdog (audit mode)
#
# Part of kallichore-watchman (MIT). Companion to posit-dev/positron#16167.
#
# What it does:
#   Inspects the Kallichore supervisor's /sessions endpoint (over its Unix
#   Domain Socket) and reports kernel sessions that look abandoned, so idle
#   R/Python kernels can be reclaimed before they eat all container memory.
#
# Safety bottom line (never violated):
#   1. connected == true  -> NEVER touched (user attached, variables live).
#   2. status == "busy"   -> NEVER touched (computation running).
#   3. Only connected == false + status == "idle" + idle_seconds > threshold
#      are listed as reclamation candidates.
#   4. This script only AUDITS (writes a log line). Reclamation itself stays
#      manual (Shut Down in the UI, or POST /sessions/<id>/kill) until you
#      have watched the log long enough to trust it.
#
# Config (environment):
#   KC_CONTAINER     container running the supervisor   (default: positron-server)
#   KC_CULLER_LOG    audit log file                     (default: ./kc-culler.log)
#   KC_IDLE_SECONDS  abandonment threshold in seconds   (default: 86400 = 24h)
#
# Cron example (host, every 15 minutes):
#   */15 * * * * /path/to/kc-culler.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CONTAINER="${KC_CONTAINER:-positron-server}"
LOG_FILE="${KC_CULLER_LOG:-./kc-culler.log}"
IDLE_THRESHOLD="${KC_IDLE_SECONDS:-86400}"
mkdir -p "$(dirname "$LOG_FILE")"

# 1. Bail quietly when the container is not running.
CID=$(docker ps -q -f name="^${CONTAINER}$" 2>/dev/null || true)
if [ -z "$CID" ]; then
  exit 0
fi

# 2. Locate the supervisor control socket (skip per-session channel sockets
#    such as kc-442.r-xxx.sock).
SOCK=$(docker exec "$CONTAINER" find /tmp -maxdepth 1 -name 'kc-[0-9]*.sock' ! -name '*.*.sock' 2>/dev/null | head -1 || true)
if [ -z "$SOCK" ]; then
  exit 0
fi

# 3. Probe for an available interpreter inside the container (never fail silent).
RUNNER=$(docker exec "$CONTAINER" sh -c 'command -v python3 || command -v node || echo ""' 2>/dev/null || true)
if [ -z "$RUNNER" ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] no python3 or node inside container $CONTAINER, cannot audit sessions" >> "$LOG_FILE"
  exit 1
fi

# 4. Fetch /sessions and audit (branch on the probed runner).
if [[ "$RUNNER" == *"python3"* ]]; then
  docker exec "$CONTAINER" python3 -c "
import subprocess, json, time, sys

sock = '$SOCK'
threshold = $IDLE_THRESHOLD
now_str = time.strftime('%Y-%m-%d %H:%M:%S')

try:
    raw = subprocess.check_output(f'curl -s --max-time 5 --unix-socket {sock} http://localhost/sessions', shell=True).decode('utf-8', errors='ignore')
except Exception as e:
    print(f'[{now_str}] [ERROR] cannot reach /sessions socket: {e}')
    sys.exit(0)

try:
    data = json.loads(raw)
except Exception as e:
    snippet = raw.strip().replace('\n', ' ')[:200]
    print(f'[{now_str}] [ERROR] cannot parse /sessions JSON: {e} | Raw: {snippet}')
    sys.exit(0)

if isinstance(data, list):
    sessions = data
elif isinstance(data, dict):
    sessions = data.get('sessions', [])
else:
    print(f'[{now_str}] [ERROR] unexpected /sessions shape: {type(data)}')
    sys.exit(0)

total = len(sessions)
total_mem_mb = 0.0
candidates = []

for s in sessions:
    if not isinstance(s, dict):
        continue
    sid = s.get('session_id', 'unknown')
    lang = s.get('language', 'unknown')
    conn = s.get('connected')
    status = s.get('status', 'unknown')
    idle = s.get('idle_seconds', 0) or 0
    mem_bytes = s.get('resource_usage', {}).get('memory_bytes', 0) or 0
    mem_mb = mem_bytes / 1024 / 1024
    total_mem_mb += mem_mb
    cwd = s.get('working_directory', '')

    if conn is False and status == 'idle' and idle > threshold:
        candidates.append((sid, lang, idle, mem_mb, cwd))

log_line = f'[{now_str}] audit: {total} sessions, {total_mem_mb:.1f} MB total kernel memory'
if candidates:
    log_line += f' | {len(candidates)} abandonment candidates (idle>{threshold}s): ' + ', '.join(f'{c[0]}({c[1]},{c[2]}s,{c[3]:.1f}MB)' for c in candidates)
else:
    log_line += ' | all sessions healthy or legitimately retained'
print(log_line)
" >> "$LOG_FILE" 2>&1 || true

else
  docker exec "$CONTAINER" node -e "
const cp = require(\"child_process\");
const sock = \"$SOCK\";
const threshold = $IDLE_THRESHOLD;
const now_str = new Date().toISOString().replace(\"T\", \" \").substring(0, 19);

let raw = \"\";
try {
  raw = cp.execSync(\"curl -s --max-time 5 --unix-socket \" + sock + \" http://localhost/sessions\", { encoding: \"utf-8\" });
} catch (e) {
  console.log(\"[\" + now_str + \"] [ERROR] cannot reach /sessions socket: \" + e.message);
  process.exit(0);
}

let data;
try {
  data = JSON.parse(raw);
} catch (e) {
  const snippet = raw.trim().replace(/\\n/g, \" \").substring(0, 200);
  console.log(\"[\" + now_str + \"] [ERROR] cannot parse /sessions JSON: \" + e.message + \" | Raw: \" + snippet);
  process.exit(0);
}

const sessions = Array.isArray(data) ? data : ((data && data.sessions) || []);
let total = sessions.length;
let total_mem_mb = 0.0;
const candidates = [];

for (const s of sessions) {
  if (!s || typeof s !== \"object\") continue;
  const sid = s.session_id || \"unknown\";
  const lang = s.language || \"unknown\";
  const conn = s.connected;
  const status = s.status || \"unknown\";
  const idle = s.idle_seconds || 0;
  const mem_bytes = (s.resource_usage && s.resource_usage.memory_bytes) || 0;
  const mem_mb = mem_bytes / 1024 / 1024;
  total_mem_mb += mem_mb;
  const cwd = s.working_directory || \"\";

  if (conn === false && status === \"idle\" && idle > threshold) {
    candidates.push([sid, lang, idle, mem_mb, cwd]);
  }
}

let log_line = \"[\" + now_str + \"] audit: \" + total + \" sessions, \" + total_mem_mb.toFixed(1) + \" MB total kernel memory\";
if (candidates.length > 0) {
  log_line += \" | \" + candidates.length + \" abandonment candidates (idle>\" + threshold + \"s): \" + candidates.map(c => c[0] + \"(\" + c[1] + \",\" + c[2] + \"s,\" + c[3].toFixed(1) + \"MB)\").join(\", \");
} else {
  log_line += \" | all sessions healthy or legitimately retained\";
}
console.log(log_line);
" >> "$LOG_FILE" 2>&1 || true
fi
