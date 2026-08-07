# ROSflight + HoloOcean Simulation Workspace

This is a ROS 2 workspace and Devsy dev container for running **ROSflight** and
**HoloOcean** simulations, with AI coding agents (Claude Code, Codex)
preinstalled. It is modeled on
[`jusevitch/rosflight_devpod`](https://github.com/jusevitch/rosflight_devpod)
and follows the official
[ROSflight sim install docs](https://docs.rosflight.org/latest/user-guide/installation/installation-sim/)
and the
[HoloOcean install docs](https://byu-holoocean.github.io/holoocean-docs/).

The key difference from the reference template: the Dockerfile adds an
"Unreal runtime dependencies" layer (glvnd + Vulkan loader/ICD + X11 libs,
adapted from the MIT-licensed adamrehn/ue4-runtime project) so the prebuilt
HoloOcean world binaries have the rendering userspace they need. Epic's
official runtime container image is NOT used as the base because it is
Ubuntu 20.04-only, which cannot host ROS 2 Humble/Jazzy (verified 2026-08:
Epic versions dev images but publishes no versioned runtime tags at all —
runtime-5.3 through runtime-5.8.1 do not exist). That image contains no
Unreal Engine code, so replicating its dependency set loses nothing.

## Project structure

- `.devcontainer/` — container definition
  - `Dockerfile` — `osrf/ros:${ROS_DISTRO}-desktop` base + Unreal runtime
    dependency layer (glvnd/Vulkan/X11) + dev tooling + non-root `rosflight`
    user
  - `devcontainer.json` — build args (`ROS_DISTRO`), features
    (Node, GitHub CLI), GPU (`--gpus=all`, `NVIDIA_DRIVER_CAPABILITIES=all`),
    X11/networking, extensions, `postCreateCommand` + `postStartCommand`
  - `setup.sh` — post-create: installs Claude Code + Codex and wires ROS
    sourcing (fast, synchronous), then launches `scripts/setup_all.sh`
    detached in the background
  - `on_start.sh` — post-start: relaunches `scripts/setup_all.sh` if any setup
    phase is incomplete (self-healing); no-op once everything is done
  - `.bash_aliases` — git + colcon shortcuts
- `.claude/settings.json` — Claude Code runs with `bypassPermissions` inside the container
- `scripts/setup_all.sh` — background orchestrator: runs the two setup scripts
  below in order, with a lock (concurrent-safe) and per-phase completion
  markers in `log/setup/`; `--status` (or the `setup-status` alias) reports
  progress
- `scripts/setup_workspace.sh` — clones the ROSflight repos, runs `rosdep`, builds with `colcon`
- `scripts/setup_holoocean.sh` — clones HoloOcean (shallow by default; the
  repo is Epic-gated, so the script hunts for GitHub credentials: `gh auth`,
  the caller's askpass/helpers, or a discovered VS Code git session — and
  waits for one if none exists yet), pip-installs `holoocean/client`,
  downloads prebuilt world packages via `holoocean.install()`;
  interruption-safe (atomic clone, world-install completion marker).
  Default package: **`Land` only** — the terrain worlds (default, desert,
  forest, island, mountains) that every ROSflight HoloOcean scenario flies
  in (see `rosflight_sim/simulators/holoocean_sim/holoocean_main/config/`).
  The underwater `Ocean` package is deliberately NOT downloaded; users who
  want AUV worlds can opt in with `HOLOOCEAN_PACKAGE="Land Ocean"`.
- `scripts/ensure_setup.sh` — tiny shared launcher: relaunches `setup_all.sh`
  detached iff setup is incomplete and not already running
- `src/` — ROS 2 packages (cloned here; gitignored)
  - `rosflight_ros_pkgs` — core ROS stack: `rosflight_io`, `rosflight_sim`, `rosflight_msgs`, and the `rosflight_firmware` submodule (SIL)
  - `rosplane` — fixed-wing autopilot (`rosplane_sim`)
  - `roscopter` — multirotor autopilot (`roscopter_sim`)
- `holoocean/` — HoloOcean repo (cloned here; gitignored; contains a
  `COLCON_IGNORE` so colcon skips it). World binaries land under the user
  profile (`~/.local/share/holoocean/`).

## Background setup (do not move it back into postCreate)

Two hard constraints shape the setup design:

1. **The HoloOcean repo is gated** (anonymous access 404s; a GitHub account
   linked to Epic is required), and during postCreate the container usually
   has NO GitHub credentials yet — no `gh auth`, an empty Devsy host-tunnel,
   and no VS Code askpass (the VS Code window attaches ~1 min into
   postCreate, and only its shells carry the askpass environment). This is
   exactly how the original synchronous setup broke: the clone 401'd
   instantly during postCreate, nothing retried it, and interactive shells —
   where the clone works thanks to VS Code askpass — masked the difference.
2. The downloads are multi-GB: they must not block `workspace up` (and
   orchestrators may kill long-running lifecycle hooks).

So the heavy setup is decoupled from the hooks:

- `postCreateCommand` (`setup.sh`) does only fast tooling, then launches
  `scripts/setup_all.sh` **detached** via `scripts/ensure_setup.sh`
  (`setsid nohup ... &`).
- `scripts/setup_holoocean.sh` finds credentials on its own: `gh auth` →
  caller's askpass/helpers → a **synthesized VS Code askpass session**
  (discovers `/tmp/vscode-git-*.sock` + `~/.vscode-server/bin/<commit>` and
  verifies with `git credential fill`) — and waits up to
  `HOLOOCEAN_CRED_WAIT_SECS` (default 30 min) for a source to appear.
- Healers relaunch anything unfinished: `postStartCommand` (`on_start.sh`)
  on every container start, and a shell-init hook in `~/.bashrc`/`~/.zshrc`
  on every interactive shell (which also carries the VS Code credential
  environment). Both go through `ensure_setup.sh`.
- `setup_all.sh` is self-locking (`flock`) and records phase markers in
  `log/setup/*.done`; the setup scripts are idempotent and
  interruption-safe (atomic clone via temp-dir + rename; world-package
  completion marker), so re-running is always safe and never repeats
  finished multi-GB work.

Practical consequences for agents working in this repo:

- **Before diagnosing "X is missing / not built"** right after container
  creation, run `bash scripts/setup_all.sh --status` (alias `setup-status`) —
  setup may simply still be running; the log is `log/setup/setup_all.log`.
- Keep anything slow or download-heavy OUT of `postCreateCommand` /
  `postStartCommand`; add it as a phase in `setup_all.sh` instead.
- To force a phase to re-run: `rm log/setup/<phase>.done`, then re-run
  `bash scripts/setup_all.sh` (or restart the container).

## ROS distribution and base image

- ROS 2 distro is configurable via the **`ROS_DISTRO` build arg** in
  `.devcontainer/devcontainer.json` (default: **`humble`**, Ubuntu 22.04).
  The `osrf/ros` base guarantees the Ubuntu release matches the distro.
- Do NOT switch the base image back to
  `ghcr.io/epicgames/unreal-engine:runtime` — it is focal-based and breaks
  the ROS install. The Unreal rendering userspace is provided by the
  dependency layer in the Dockerfile instead.
- Gazebo Classic only works on **Humble**. On Jazzy, use the standalone
  (RViz) sims and HoloOcean.

## EULA constraints (do not "fix" these)

- Never vendor Unreal Engine or HoloOcean code, binaries, or world packages
  into this repo, and never add CI that pushes a built image containing the
  HoloOcean clone or world packages to a public registry. The clone-at-setup
  design is deliberate EULA compliance, not an inefficiency. (The bare image
  from the Dockerfile contains no Epic code and is not itself encumbered.)
- The HoloOcean clone requires per-user Epic-linked GitHub credentials. Do not
  bake tokens into the image or the repo.

## Building

Always source ROS 2 (and the workspace, once built) before running commands.
From the workspace root:

```bash
source /opt/ros/${ROS_DISTRO}/setup.bash   # ROS_DISTRO defaults to humble
colcon build --symlink-install
source install/setup.bash
```

The devcontainer runs this automatically on creation via
`scripts/setup_workspace.sh` — **in the background** (see
"Background setup" below), so right after the first launch the workspace may
still be building. To rebuild a single package:

```bash
colcon build --symlink-install --packages-select <package_name>
```

If memory is constrained: `colcon build --executor sequential`.

## Running simulations

Run from the workspace root with the workspace sourced.

```bash
# ROSflight standalone (RViz) sim
ros2 launch rosflight_sim multirotor_standalone.launch.py
ros2 launch rosflight_sim fixedwing_standalone.launch.py
# Add keyboard manual control (VimFly):
ros2 launch rosflight_sim multirotor_standalone.launch.py use_vimfly:=true

# Autopilot sims
ros2 launch rosplane_sim sim.launch.py      # fixed-wing
ros2 launch roscopter_sim sim.launch.py     # multirotor

# ROSflight UAVs flying in HoloOcean worlds (the reason the Land package is installed)
ros2 launch rosflight_sim multirotor_holoocean.launch.py    # env:=default|desert|forest|island|mountains
ros2 launch rosflight_sim fixedwing_holoocean.launch.py

# HoloOcean smoke test (opens a world window; needs GPU + X11)
python3 -c "import holoocean; env = holoocean.make('default_multirotor'); [env.tick() for _ in range(300)]"

# Inspect installed HoloOcean worlds/scenarios
python3 -c "from holoocean import packagemanager; packagemanager.package_info('Land')"
```

GUI apps (RViz, PlotJuggler, HoloOcean windows) display on the host over X11.
If windows do not appear, run `xhost +local:docker` on the host. GPU sanity
checks inside the container: `nvidia-smi`, `vulkaninfo --summary`.

## Included tools

- **AI coding agents:** Claude Code (Anthropic), Codex CLI (OpenAI)
- **ROS 2** (`humble` by default) + `ros-dev-tools`, `plotjuggler`, `colcon`, `rosdep`
- **HoloOcean** Python client + prebuilt `Land` world package (the
  ROSflight-flyable terrain worlds; `Ocean` is opt-in)
- **Dev tools:** Node.js, uv (Python package/env manager, with a managed Python 3.12), Rust (rustup), GitHub CLI, git, tmux, Zellij, ripgrep, vim, vulkan-tools

The default shell is **bash**. zsh is still installed if you prefer it, but note
that colcon's `install/setup.bash` cannot be sourced from zsh (it relies on
`$BASH_SOURCE`) — under zsh use `install/setup.zsh` instead.

## Conventions

- The three `src/` repos and `holoocean/` are cloned, not vendored — do not
  commit their contents to this repo. Edit them in place; each has its own
  upstream git history.
- Keep `scripts/setup_all.sh`, `scripts/setup_workspace.sh`, and
  `scripts/setup_holoocean.sh` idempotent (safe to re-run) AND
  interruption-safe (safe to kill at any moment and re-run — the background
  setup can be interrupted by container stops).
- `setup_holoocean.sh` deliberately clones with git credential helpers
  cleared (using `gh auth git-credential` when authenticated) because
  the credential helper injected by DevPod-lineage tools can crash the
  (unmaintained) DevPod host agent mid-startup. Do not "simplify" the clone
  back to a plain `git clone`.
- `rosflight_firmware` is a git submodule of `rosflight_ros_pkgs`.
- The HoloOcean client is installed with `pip install --user`; on
  noble-based images the scripts add `--break-system-packages` automatically.
