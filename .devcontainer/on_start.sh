#!/usr/bin/env bash
#
# postStartCommand for the ROSflight + HoloOcean Sim devcontainer.
#
# Self-healing setup: if the heavy setup (ROSflight workspace build +
# HoloOcean clone/world download, run by scripts/setup_all.sh) has not
# finished — e.g. the previous container session was stopped mid-download —
# relaunch it, detached, on every container start. Instant no-op once all
# phases are complete.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
exec bash "${WS_ROOT}/scripts/ensure_setup.sh"
