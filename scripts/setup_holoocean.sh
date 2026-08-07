#!/usr/bin/env bash
#
# setup_holoocean.sh — set up HoloOcean (client + prebuilt world packages).
#
# Clones the HoloOcean repository (idempotently — an existing clone is left
# untouched), pip-installs the Python client, and downloads prebuilt world
# packages via holoocean.install(). Nothing Unreal-derived is vendored in this
# repo: everything is fetched at setup time under YOUR credentials and license
# acceptances.
#
# Default package: Land (~2 GB) — the terrain worlds (default, desert, forest,
# island, mountains) that rosflight_sim's HoloOcean scenarios fly UAVs in
# (see rosflight_sim/simulators/holoocean_sim/holoocean_main/config/*.json:
# every ROSflight scenario uses package_name "Land"). The underwater Ocean
# package (~5 GB) is NOT needed for ROSflight; add it only if you want the
# AUV worlds: HOLOOCEAN_PACKAGE="Land Ocean" bash scripts/setup_holoocean.sh
#
# Interruption-safe by design (the devcontainer orchestrator can kill setup
# jobs, and the downloads are multi-GB):
#   * The clone is shallow (--depth 1) by default, retried on failure, and
#     lands in a temp dir that is atomically renamed into place — holoocean/
#     exists only if the clone completed.
#   * The world package download is guarded by a completion marker; a
#     partially extracted package from an interrupted run is detected,
#     removed, and re-downloaded.
# The script is safe to re-run at any time; finished steps are skipped.
#
# Authentication: the HoloOcean GitHub repository is gated — it is visible
# only to GitHub accounts linked to an Epic Games account (accepting the
# Unreal Engine EULA): https://www.unrealengine.com/en-US/ue-on-github
# (Anonymous access 404s, so the clone MUST authenticate.) Credential sources,
# in the order this script tries them:
#   1. The GitHub CLI, if authenticated ('gh auth login').
#   2. The caller's git credential environment (helpers + GIT_ASKPASS) — in a
#      VS Code terminal this is VS Code's git sign-in, forwarded from the host.
#   3. A synthesized VS Code askpass environment: when running detached (the
#      background setup job has no VS Code env), the script discovers a live
#      VS Code git IPC socket (/tmp/vscode-git-*.sock) plus the server install
#      under ~/.vscode-server and borrows that session's credentials. If no
#      source is available yet, it waits up to HOLOOCEAN_CRED_WAIT_SECS for
#      one to appear (the VS Code window usually attaches well before the
#      earlier setup phases finish).
# If the clone still fails with "Repository not found"/authentication errors:
#   1. Link your accounts (see the URL above), and
#   2. make sure the container can authenticate to GitHub — easiest is
#      'gh auth login' — then re-run: bash scripts/setup_holoocean.sh
#
# Usage:
#   bash scripts/setup_holoocean.sh
#
# Environment variables:
#   HOLOOCEAN_REPO_URL     Clone URL. Default:
#                          https://github.com/byu-holoocean/HoloOcean.git
#                          (Set to the byu-holoocean-mirror URL if your account
#                          is on Epic's mirror organization.)
#   HOLOOCEAN_REF          Branch/tag to check out (default: repo default branch)
#   HOLOOCEAN_CLONE_DEPTH  History depth for the clone (default: 1, i.e. a
#                          shallow single-branch clone — the repo's full
#                          history is several GB of Unreal assets). Set to 0
#                          for a full clone; deepen an existing shallow clone
#                          any time with: git -C holoocean fetch --unshallow
#   HOLOOCEAN_PACKAGE      World package(s) to download, space- or comma-
#                          separated (default: Land — the only package the
#                          ROSflight HoloOcean sims use). Known packages:
#                          Land, Ocean, TestWorlds, BusinessCampus, Island.
#   HOLOOCEAN_SKIP_WORLDS  If set to 1, skip the world package download
#                          (it is several GB). You can run it later with:
#                          bash scripts/setup_holoocean.sh
#   HOLOOCEAN_CRED_WAIT_SECS  How long to wait for a GitHub credential source
#                          to appear before the final clone attempt
#                          (default: 1800; only waits when the first attempt
#                          fails and no source is visible)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOLOOCEAN_DIR="${WS_ROOT}/holoocean"
HOLOOCEAN_REPO_URL="${HOLOOCEAN_REPO_URL:-https://github.com/byu-holoocean/HoloOcean.git}"
HOLOOCEAN_REF="${HOLOOCEAN_REF:-}"
HOLOOCEAN_CLONE_DEPTH="${HOLOOCEAN_CLONE_DEPTH:-1}"
HOLOOCEAN_PACKAGE="${HOLOOCEAN_PACKAGE:-Land}"
HOLOOCEAN_SKIP_WORLDS="${HOLOOCEAN_SKIP_WORLDS:-0}"

log() { printf '\n\033[1;36m[setup_holoocean]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[setup_holoocean]\033[0m %s\n' "$*"; }

# retry <n> <sleep_s> <cmd...>: run <cmd> up to <n> times, sleeping between tries.
retry() {
    local tries="$1" pause="$2" i
    shift 2
    for ((i = 1; i <= tries; i++)); do
        if "$@"; then return 0; fi
        if ((i < tries)); then
            warn "Attempt ${i}/${tries} failed; retrying in ${pause}s: $*"
            sleep "${pause}"
        fi
    done
    return 1
}

# --- 1. Clone the HoloOcean repo (idempotent, atomic) --------------------------
# Credential strategy (see the header). One extra constraint: DevPod-lineage
# tools inject a git credential helper that fetches credentials from the HOST
# over a gRPC tunnel. The unmaintained DevPod crashes (nil-pointer panic in
# tunnelserver.GitCredentials) when that helper fires during postCreate and
# the host has nothing to forward -- killing the whole workspace startup.
# Devsy maintains this code path, so helpers naming 'devsy' are kept while
# helpers naming 'devpod' are stripped. Set
# HOLOOCEAN_USE_DEFAULT_GIT_HELPERS=1 to keep ALL configured helpers as-is.
DEPTH_ARGS=()
if [ "${HOLOOCEAN_CLONE_DEPTH}" != "0" ] && [ "${HOLOOCEAN_CLONE_DEPTH}" != "full" ]; then
    DEPTH_ARGS=(--depth "${HOLOOCEAN_CLONE_DEPTH}" --single-branch)
fi

# find_vscode_askpass: discover a live VS Code git credential session usable
# from a detached process. Prints "<server_dir>\n<socket>" and returns 0 only
# after verifying the combination actually yields a GitHub credential.
find_vscode_askpass() {
    local sock base
    for sock in $(ls -t /tmp/vscode-git-*.sock 2>/dev/null); do
        [ -S "${sock}" ] || continue
        for base in $(ls -td "${HOME}/.vscode-server/bin"/*/ 2>/dev/null); do
            base="${base%/}"
            [ -x "${base}/node" ] && [ -f "${base}/extensions/git/dist/askpass.sh" ] || continue
            if printf 'protocol=https\nhost=github.com\n\n' | env \
                GIT_ASKPASS="${base}/extensions/git/dist/askpass.sh" \
                VSCODE_GIT_ASKPASS_NODE="${base}/node" \
                VSCODE_GIT_ASKPASS_MAIN="${base}/extensions/git/dist/askpass-main.js" \
                VSCODE_GIT_ASKPASS_EXTRA_ARGS="" \
                VSCODE_GIT_IPC_HANDLE="${sock}" \
                GIT_TERMINAL_PROMPT=0 git -c credential.helper= credential fill 2>/dev/null \
                | grep -q '^password='; then
                printf '%s\n%s\n' "${base}" "${sock}"
                return 0
            fi
        done
    done
    return 1
}

# have_cred_hint: is any GitHub credential source visible right now?
have_cred_hint() {
    [ -n "${GIT_ASKPASS:-}" ] && return 0
    command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 && return 0
    ls /tmp/vscode-git-*.sock >/dev/null 2>&1 && return 0
    return 1
}

clone_holoocean() {
    local dest="$1"
    rm -rf "${dest}"
    local -a git_args=()
    local -a extra_env=(GIT_TERMINAL_PROMPT=0)
    if [ "${HOLOOCEAN_USE_DEFAULT_GIT_HELPERS:-0}" != "1" ]; then
        # Rebuild the helper list without the crash-prone DevPod tunnel.
        git_args+=(-c credential.helper=)
        local h
        while IFS= read -r h; do
            [ -n "${h}" ] || continue
            case "${h}" in *devpod*) continue ;; esac
            git_args+=(-c "credential.helper=${h}")
        done < <(git config --get-all credential.helper 2>/dev/null || true)
        if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
            git_args+=(-c 'credential.helper=!gh auth git-credential')
        fi
    fi
    # Detached runs have no askpass of their own: borrow a live VS Code git
    # session if one can be found and verified.
    if [ -z "${GIT_ASKPASS:-}" ]; then
        local synth base sock
        if synth="$(find_vscode_askpass)"; then
            base="${synth%%$'\n'*}"
            sock="${synth##*$'\n'}"
            log "Borrowing the VS Code git credential session (${sock})."
            extra_env+=(
                GIT_ASKPASS="${base}/extensions/git/dist/askpass.sh"
                VSCODE_GIT_ASKPASS_NODE="${base}/node"
                VSCODE_GIT_ASKPASS_MAIN="${base}/extensions/git/dist/askpass-main.js"
                VSCODE_GIT_ASKPASS_EXTRA_ARGS=""
                VSCODE_GIT_IPC_HANDLE="${sock}"
            )
        fi
    fi
    env "${extra_env[@]}" git "${git_args[@]}" \
        clone "${DEPTH_ARGS[@]}" "${HOLOOCEAN_REPO_URL}" "${dest}"
}

# Clear residue from previous interrupted runs.
rm -rf "${HOLOOCEAN_DIR}".tmp.* "${WS_ROOT}"/.holoocean.tmp.*
if [ -d "${HOLOOCEAN_DIR}" ] && [ ! -d "${HOLOOCEAN_DIR}/.git" ]; then
    warn "Removing ${HOLOOCEAN_DIR}: exists but is not a git repo (interrupted clone residue)."
    rm -rf "${HOLOOCEAN_DIR}"
fi

clone_with_cred_wait() {
    local dest="$1"
    # First attempt with whatever is available right now (succeeds immediately
    # in credentialed shells; fails in ~seconds when nothing can authenticate).
    if clone_holoocean "${dest}"; then return 0; fi
    if ! have_cred_hint; then
        local wait_secs="${HOLOOCEAN_CRED_WAIT_SECS:-1800}"
        local deadline=$(($(date +%s) + wait_secs))
        log "No GitHub credential source is visible yet (no 'gh auth login', no"
        log "VS Code session). The repo is gated, so the clone must authenticate."
        log "Waiting up to $((wait_secs / 60)) min for a source to appear — opening"
        log "the workspace in VS Code (its GitHub sign-in provides credentials) or"
        log "running 'gh auth login' both end the wait."
        while ! have_cred_hint && [ "$(date +%s)" -lt "${deadline}" ]; do
            sleep 15
        done
        if have_cred_hint; then
            log "Credential source detected; retrying the clone."
        else
            log "No credential source appeared within $((wait_secs / 60)) min; trying anyway."
        fi
    fi
    retry 3 15 clone_holoocean "${dest}"
}

if [ -d "${HOLOOCEAN_DIR}/.git" ]; then
    log "HoloOcean repo already present at ${HOLOOCEAN_DIR}; skipping clone."
else
    # Dot-dir: colcon skips hidden directories, so a clone-in-progress can
    # never be discovered as a package by a concurrent workspace build.
    CLONE_TMP="${WS_ROOT}/.holoocean.tmp.$$"
    log "Cloning ${HOLOOCEAN_REPO_URL} -> ${HOLOOCEAN_DIR} (depth: ${HOLOOCEAN_CLONE_DEPTH})"
    if ! clone_with_cred_wait "${CLONE_TMP}"; then
        rm -rf "${CLONE_TMP}"
        warn "Clone failed. The HoloOcean repo is gated: it needs GitHub credentials"
        warn "from an account linked to an Epic Games account. To fix, either open"
        warn "the workspace in VS Code (signed in to GitHub) and re-run this script"
        warn "from its terminal, or run INSIDE the container:"
        warn "    gh auth login"
        warn "    bash scripts/setup_holoocean.sh"
        warn "Other possible causes:"
        warn "  * GitHub account not linked to an Epic Games account"
        warn "    -> https://www.unrealengine.com/en-US/ue-on-github"
        warn "  * Your account is on Epic's mirror org"
        warn "    -> HOLOOCEAN_REPO_URL=https://github.com/byu-holoocean-mirror/HoloOcean.git bash scripts/setup_holoocean.sh"
        exit 1
    fi
    # Tag the clone BEFORE it becomes visible: the workspace phase can run a
    # colcon build at any time, and without this marker colcon would try to
    # build the HoloOcean client as a ROS package (its setup.py then fails
    # and aborts the whole build).
    touch "${CLONE_TMP}/COLCON_IGNORE"
    # Atomic: holoocean/ appears only as a complete clone.
    mv "${CLONE_TMP}" "${HOLOOCEAN_DIR}"
fi

if [ -n "${HOLOOCEAN_REF}" ]; then
    log "Checking out '${HOLOOCEAN_REF}'..."
    if ! git -C "${HOLOOCEAN_DIR}" checkout "${HOLOOCEAN_REF}" 2>/dev/null; then
        # Shallow clones only carry the default branch; fetch the ref first.
        git -C "${HOLOOCEAN_DIR}" fetch --depth 1 origin "${HOLOOCEAN_REF}"
        git -C "${HOLOOCEAN_DIR}" checkout FETCH_HEAD
    fi
fi

# Keep colcon from treating the HoloOcean client as a workspace package.
touch "${HOLOOCEAN_DIR}/COLCON_IGNORE"

# --- 2. pip install the client ------------------------------------------------
# Newer Ubuntu (noble) marks the system Python "externally managed"; pass
# --break-system-packages there. On jammy the flag does not exist.
PIP_FLAGS=(--user)
if python3 -m pip install --help 2>/dev/null | grep -q -- '--break-system-packages'; then
    PIP_FLAGS+=(--break-system-packages)
fi

log "Installing the HoloOcean Python client (pip)..."
retry 3 15 python3 -m pip install "${PIP_FLAGS[@]}" "${HOLOOCEAN_DIR}/client"

# --- 3. Download the prebuilt world package -----------------------------------
# holoocean.install() downloads + extracts several GB. If a previous run was
# interrupted mid-extraction, packagemanager would report the package as
# installed even though it is incomplete — so completion is tracked with a
# marker file next to the worlds, and anything without a marker is wiped and
# re-downloaded.
install_world() {
    # tr+uniq: holoocean's download progress bar redraws with '\r' thousands
    # of times; collapse it so log files stay small. pipefail (set above)
    # still surfaces a python failure as the function's exit code.
    local pkg="$1"
    python3 - <<PY | stdbuf -oL tr '\r' '\n' | stdbuf -oL uniq
import sys
from pathlib import Path

import holoocean
from holoocean import packagemanager, util

package = "${pkg}"
marker = Path(util.get_holoocean_path()) / f".{package}.install_complete"

if package in packagemanager.installed_packages():
    if marker.is_file():
        print(f"Package '{package}' already installed; skipping.")
        sys.exit(0)
    # holoocean.install() would silently accept the partial package, so it
    # must be removed first.
    print(f"Package '{package}' present but has no completion marker "
          "(interrupted download?); removing and re-installing.")
    packagemanager.remove(package)

marker.unlink(missing_ok=True)
holoocean.install(package)
marker.parent.mkdir(parents=True, exist_ok=True)
marker.touch()
print(f"Package '{package}' installed.")
PY
}

if [ "${HOLOOCEAN_SKIP_WORLDS}" = "1" ]; then
    log "HOLOOCEAN_SKIP_WORLDS=1 set; skipping the '${HOLOOCEAN_PACKAGE}' world download."
    log "Download later by re-running: bash scripts/setup_holoocean.sh"
else
    for pkg in ${HOLOOCEAN_PACKAGE//,/ }; do
        log "Downloading the '${pkg}' world package (several GB; this can take a while)..."
        retry 3 30 install_world "${pkg}"
    done
fi

# --- Done ---------------------------------------------------------------------
cat <<EOF

$(log "HoloOcean ready.")
Smoke test (opens a world window; needs the GPU + X11 wiring from devcontainer.json):
  python3 -c "import holoocean; env = holoocean.make('default_multirotor'); [env.tick() for _ in range(300)]"

Fly ROSflight UAVs in the HoloOcean worlds (from a sourced workspace):
  ros2 launch rosflight_sim multirotor_holoocean.launch.py   # env:=default|desert|forest|island|mountains
  ros2 launch rosflight_sim fixedwing_holoocean.launch.py

List installed worlds/scenarios:
  python3 -c "from holoocean import packagemanager; packagemanager.package_info('Land')"

HoloOcean examples and ROS 2 usage: see ${HOLOOCEAN_DIR} and
https://byu-holoocean.github.io/holoocean-docs/
EOF
