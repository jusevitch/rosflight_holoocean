#!/usr/bin/env bash
#
# setup_all.sh — orchestrate the heavy workspace setup (ROSflight + HoloOcean).
#
# Runs scripts/setup_workspace.sh and scripts/setup_holoocean.sh in order,
# recording a completion marker for each phase so finished work is never
# repeated. Self-locking: a second concurrent instance exits immediately, so
# it is always safe to launch (postCreate, postStart, and manual runs can all
# fire it blindly).
#
# The devcontainer launches this DETACHED (setsid + nohup) from
# .devcontainer/setup.sh, .devcontainer/on_start.sh, and a shell-init hook:
# the multi-GB HoloOcean downloads must not block `workspace up` (and
# orchestrators may kill long-running lifecycle hooks), and the gated
# HoloOcean clone needs GitHub credentials that typically appear only after
# a VS Code window attaches. Progress goes to log/setup/setup_all.log; check
# it with:  bash scripts/setup_all.sh --status  (or the 'setup-status' alias).
#
# Usage:
#   bash scripts/setup_all.sh            # run (or resume) the setup
#   bash scripts/setup_all.sh --status   # show phase states + recent log
#
# To force a phase to re-run, delete its marker under log/setup/ and re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_DIR="${WS_ROOT}/log/setup"
LOG_FILE="${STATE_DIR}/setup_all.log"
LOCK_FILE="${STATE_DIR}/lock"

mkdir -p "${STATE_DIR}"

log() { printf '\n\033[1;35m[setup_all]\033[0m [%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

phase_state() {
    # phase_state <name>: done | running | pending
    if [ -f "${STATE_DIR}/$1.done" ]; then echo done; return; fi
    if ! flock -n -x "${LOCK_FILE}" true 2>/dev/null; then echo "running"; return; fi
    echo pending
}

if [ "${1:-}" = "--status" ]; then
    echo "Setup state (${STATE_DIR}):"
    echo "  workspace (ROSflight clone + rosdep + colcon build): $(phase_state workspace)"
    echo "  holoocean (clone + client + Land world download):    $(phase_state holoocean)"
    if flock -n -x "${LOCK_FILE}" true 2>/dev/null; then
        echo "  setup job: not running"
    else
        echo "  setup job: RUNNING (follow with: tail -f ${LOG_FILE})"
    fi
    if [ -f "${LOG_FILE}" ]; then
        echo
        echo "Last log lines (${LOG_FILE}):"
        tail -n 15 "${LOG_FILE}" | sed 's/^/  | /'
    fi
    exit 0
fi

# --- Single-instance lock ------------------------------------------------------
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    log "Another setup_all.sh instance is already running; exiting."
    exit 0
fi

run_phase() {
    # run_phase <name> <script> : run <script> unless <name>.done exists.
    # Returns the script's exit code; writes the marker on success.
    local name="$1" script="$2"
    if [ -f "${STATE_DIR}/${name}.done" ]; then
        log "Phase '${name}' already complete; skipping. (rm ${STATE_DIR}/${name}.done to force)"
        return 0
    fi
    log "Phase '${name}' starting (${script})..."
    if bash "${script}"; then
        date > "${STATE_DIR}/${name}.done"
        log "Phase '${name}' complete."
        return 0
    else
        local rc=$?
        log "Phase '${name}' FAILED (exit ${rc}). It will be retried on the next"
        log "container start, or run manually: bash ${script}"
        return "${rc}"
    fi
}

log "=== setup_all.sh run starting (pid $$) ==="

overall=0
run_phase workspace "${SCRIPT_DIR}/setup_workspace.sh" || overall=1
run_phase holoocean "${SCRIPT_DIR}/setup_holoocean.sh" || overall=1

if [ "${overall}" = "0" ]; then
    log "=== All setup phases complete. ==="
    log "HoloOcean UAV sim: ros2 launch rosflight_sim multirotor_holoocean.launch.py"
else
    log "=== Setup finished with FAILED phases (see above). ==="
fi
exit "${overall}"
