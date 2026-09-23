#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# kc-sweeper — Kallichore orphan-socket sweeper (tombstone janitor)
#
# Part of kallichore-watchman (MIT). Companion to posit-dev/positron#16167.
#
# What it does:
#   A crashed supervisor (kill -9 / OOM / segfault) may never unlink its
#   /tmp/kc-<pid>.sock. If that PID number is later recycled by a worker
#   thread, both `kill(pid, 0)` and socket-existence checks report "alive"
#   and the dead entry becomes a permanent tombstone. This script finds such
#   orphan sockets with a triple gate:
#     1. Process fingerprint: /proc/<pid>/comm must read exactly "kcserver".
#     2. Liveness probe: GET /status over the socket (one retry after 2s to
#        ride out restarts), with hard timeouts so a half-dead listener can
#        never wedge the cron job.
#     3. Audit-first: DRY-RUN (log only) unless KC_SWEEP=1.
#
# Config (environment):
#   KC_CONTAINER   container running the supervisor (default: positron-server)
#   KC_SWEEPER_LOG audit log file                   (default: ./kc-sweeper.log)
#   KC_SWEEP       0 = log only (default), 1 = unlink dead sockets
#
# Cron example (host, every 30 minutes):
#   */30 * * * * /path/to/kc-sweeper.sh
#
# Recommended rollout: run with KC_SWEEP=0 for 1-2 weeks. Flip to 1 only when
# the log shows zero false positives (every candidate independently verified).
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CONTAINER="${KC_CONTAINER:-positron-server}"
LOG_FILE="${KC_SWEEPER_LOG:-./kc-sweeper.log}"
SWEEP="${KC_SWEEP:-0}"
mkdir -p "$(dirname "$LOG_FILE")"

# 1. Bail quietly when the container is not running.
CID=$(docker ps -q -f name="^${CONTAINER}$" 2>/dev/null || true)
if [ -z "$CID" ]; then
  exit 0
fi

# 2. Scan control sockets inside the container and audit each one.
docker exec "$CONTAINER" sh -c '
now_str=$(date "+%Y-%m-%d %H:%M:%S")
sweep='"$SWEEP"'

# Control sockets only (skip per-session channels like kc-442.r-xxx.sock).
socks=$(find /tmp -maxdepth 1 -name "kc-[0-9]*.sock" ! -name "*.*.sock" 2>/dev/null || true)
if [ -z "$socks" ]; then
  exit 0
fi

total_scanned=0
dead_candidates=0

for sock in $socks; do
  total_scanned=$((total_scanned + 1))

  # PID from socket name: /tmp/kc-442.sock -> 442
  pid=$(basename "$sock" .sock | sed "s/^kc-//")

  # Gate 1: kernel-level process fingerprint. A recycled worker thread
  # (e.g. tokio-rt-worker) fails this even when kill(pid, 0) would succeed.
  comm=$(cat "/proc/$pid/comm" 2>/dev/null || echo "DEAD")

  is_alive=0
  reason=""

  if [ "$comm" != "kcserver" ]; then
    is_alive=0
    reason="process fingerprint mismatch (comm=$comm, want=kcserver)"
  else
    # Gate 2: socket handshake, with one 2s retry to ride out restarts.
    if curl -s --max-time 5 --connect-timeout 3 --unix-socket "$sock" http://localhost/status >/dev/null 2>&1; then
      is_alive=1
    else
      sleep 2
      if curl -s --max-time 5 --connect-timeout 3 --unix-socket "$sock" http://localhost/status >/dev/null 2>&1; then
        is_alive=1
      else
        is_alive=0
        reason="socket handshake silent (2 consecutive failures)"
      fi
    fi
  fi

  if [ "$is_alive" -eq 0 ]; then
    dead_candidates=$((dead_candidates + 1))
    if [ "$sweep" = "1" ]; then
      rm -f "$sock" 2>/dev/null || true
      echo "[$now_str] [SWEEP] unlinked orphan socket: $sock (PID=$pid) -> $reason"
    else
      echo "[$now_str] [DRY-RUN] orphan socket candidate: $sock (PID=$pid) -> $reason [kept, would unlink with KC_SWEEP=1]"
    fi
  fi
done

if [ "$dead_candidates" -eq 0 ]; then
  echo "[$now_str] audit: scanned $total_scanned control sockets, all supervisors and channels healthy"
fi
' >> "$LOG_FILE" 2>&1 || true
