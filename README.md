# kallichore-watchman

Two small, dependency-free watchdogs for self-hosted [Positron Server](https://github.com/posit-dev/positron) (`Kallichore` kernel supervisor) deployments. They watch what the IDE itself never reaps, and they do it read-only until you tell them otherwise.

Companion to [posit-dev/positron#16167](https://github.com/posit-dev/positron/issues/16167) (stale supervisor tombstones from Linux TID collisions) and its fix, [posit-dev/positron#16176](https://github.com/posit-dev/positron/pull/16176).

## Scripts

| Script | Watches | Rule | Default action |
|---|---|---|---|
| `kc-culler.sh` | Kernel **sessions** (`/sessions`) | `connected == false` + `status == idle` + `idle_seconds > threshold` (default 24h) | log only |
| `kc-sweeper.sh` | Supervisor **sockets** (`/tmp/kc-*.sock`) | `/proc/<pid>/comm != kcserver`, or `/status` handshake silent twice | log only (`DRY-RUN`) |

Why two? Sessions eat **memory**; orphan sockets create immortal UI **tombstones**. Different corpses, different janitors.

Why not just `kill(pid, 0)`? On Linux, thread IDs share the PID number space — a dead supervisor's PID recycled by a worker thread (e.g. `tokio-rt-worker`) still answers “alive”. The sweeper fingerprints `/proc/<pid>/comm` instead. A crashed supervisor (`kill -9`/OOM) may also never unlink its socket, blinding existence checks — hence the live handshake probe.

## Quick start

```bash
# every 15 min: audit kernel sessions
*/15 * * * * /opt/watchman/kc-culler.sh
# every 30 min: audit supervisor sockets
*/30 * * * * /opt/watchman/kc-sweeper.sh
```

```bash
# config is 100% environment (show defaults)
KC_CONTAINER=positron-server KC_CULLER_LOG=./kc-culler.log KC_IDLE_SECONDS=86400 ./kc-culler.sh
KC_CONTAINER=positron-server KC_SWEEPER_LOG=./kc-sweeper.log KC_SWEEP=0 ./kc-sweeper.sh
```

Both scripts probe for `python3`/`node` **inside** the container and speak to Kallichore over its Unix socket — no credentials, no open ports, no dependencies beyond `docker`, `curl`, and a shell.

## Rollout discipline (read this)

1. Run everything in audit mode for 1–2 weeks. Read the logs.
2. Flip `KC_SWEEP=1` only when every logged candidate was independently verified dead.
3. Reclamation of kernel *sessions* stays manual (`Shut Down` in the UI) by design — automation ends at accurate identification.

## Requirements

- Linux Docker host; a container running Positron Server with `curl` and (`python3` or `node`) inside
- Cron (or any scheduler) on the host

## License

MIT — see [LICENSE](LICENSE).
