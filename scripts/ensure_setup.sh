#!/usr/bin/env bash
#
# ensure_setup.sh — (re)launch the background setup if it is incomplete.
#
# Shared by .devcontainer/setup.sh (postCreate), .devcontainer/on_start.sh
# (postStart), and the shell-init hook appended to ~/.bashrc / ~/.zshrc.
# Instant, silent no-op when setup is complete or already running, so it is
# safe (and cheap) to call from every shell.
#
# Why the shell-init hook exists: the HoloOcean repo is gated, and the
# needed GitHub credentials often first become available inside an
# IDE-attached shell (VS Code's git askpass). Relaunching from such a shell
# hands the detached setup job a working credential environment (and
# setup_holoocean.sh can also discover a VS Code session on its own).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_DIR="${WS_ROOT}/log/setup"

if [ -f "${STATE_DIR}/workspace.done" ] && [ -f "${STATE_DIR}/holoocean.done" ]; then
    exit 0
fi

mkdir -p "${STATE_DIR}"

# Already running? (setup_all.sh holds an exclusive flock while it runs; the
# probe is advisory only — setup_all.sh itself locks authoritatively.)
if ! flock -n -x "${STATE_DIR}/lock" true 2>/dev/null; then
    exit 0
fi

echo "[ensure_setup] Workspace/HoloOcean setup is incomplete — resuming it in the background."
echo "[ensure_setup] Progress: setup-status   (log: ${STATE_DIR}/setup_all.log)"
# setsid + nohup: survive the launching shell/lifecycle hook and its terminal.
setsid nohup bash "${WS_ROOT}/scripts/setup_all.sh" \
    >> "${STATE_DIR}/setup_all.log" 2>&1 < /dev/null &
exit 0
