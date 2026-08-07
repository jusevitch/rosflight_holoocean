# ROSflight + HoloOcean Devsy Workspace

A [Devsy](https://devsy.sh) workspace (dev container) for developing and running
[ROSflight](https://rosflight.org) and [HoloOcean](https://byu-holoocean.github.io/holoocean-docs/)
simulations. Modeled on
[`jusevitch/rosflight_devpod`](https://github.com/jusevitch/rosflight_devpod):
same `osrf/ros:${ROS_DISTRO}-desktop` base, plus an "Unreal runtime
dependencies" layer (glvnd/Vulkan/X11, adapted from the MIT-licensed
[ue4-runtime](https://github.com/adamrehn/ue4-runtime) project that Epic's own
runtime container image is derived from) so the prebuilt HoloOcean worlds can
render.

> **Why not Epic's official runtime image as the base?** Epic versions its
> dev images but not its runtime images: as of 2026-08, the unversioned
> `runtime` tag (Ubuntu 20.04) is the only runtime image published — no
> `runtime-5.3` through `runtime-5.8.1` tags exist — and 20.04 cannot host
> ROS 2 Humble/Jazzy. Since that image contains no Unreal Engine code — only
> an Ubuntu graphics userspace — replicating its dependency set here loses
> nothing, legally or technically.

This repo contains **no Unreal Engine or HoloOcean code or binaries** — only
build recipes. Everything license-gated is pulled at build/setup time under
your own credentials and EULA acceptance. See [Licensing notes](#licensing-notes).

## Prerequisites

Install the following:

- [Docker](https://docs.docker.com/get-docker/)
- [Devsy](https://devsy.sh/docs/getting-started/install) (CLI or desktop app) —
  the maintained fork of DevPod, which
  [is no longer maintained](https://github.com/loft-sh/devpod/issues/1992)
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
  (an NVIDIA GPU is required for the HoloOcean worlds)
- An X11 server on the host (standard on Linux) for GUI sim tools

Install the Devsy CLI (macOS/Linux via Homebrew; see the
[install docs](https://devsy.sh/docs/getting-started/install) for other
platforms or the desktop app):

```bash
brew install devsy-org/homebrew-tap/devsy
```

Add Docker as a provider the first time you install Devsy:

```bash
devsy provider add docker
```

## Authentication (one-time, before first launch)

The container base images are public — no `docker login` is needed. The only
Epic-gated step is cloning the HoloOcean repository (anonymous access returns
404):

1. **Link GitHub to Epic.** Follow
   <https://www.unrealengine.com/en-US/ue-on-github> and accept the EULA. Wait
   for the invitation to the EpicGames GitHub organization and accept it. You
   can confirm it worked when <https://github.com/byu-holoocean/HoloOcean>
   stops returning 404 for you (while signed in to GitHub in the browser).
2. **Git credentials for the HoloOcean clone.** Usually nothing to do: the
   background setup borrows the **VS Code GitHub sign-in** of the window that
   `devsy workspace up . --ide vscode` opens (it waits up to 30 min for a
   credential source to appear, so the clone starts as soon as the window
   attaches). If you are signed in to GitHub in VS Code on the host with the
   Epic-linked account, the clone just works. For headless use — or if the
   wait expires — authenticate the GitHub CLI inside the container instead;
   the setup picks it up automatically on its next attempt (or immediately
   via `bash scripts/setup_all.sh`):

   ```bash
   gh auth login          # one-time, device-code flow
   ```

## Quick start

Run the following from the project's root directory:

```bash
devsy workspace up . --ide vscode
```

This will launch a VSCode window that is ssh'ed into a Docker container with
ROSflight, ROS2, and HoloOcean installed. This one command is all that is
needed — but note the heavy lifting is **asynchronous**: postCreate only
installs the fast tooling, then hands off to `scripts/setup_all.sh`, which
keeps running **in the background** to clone + build the ROS workspace and
clone HoloOcean + download the prebuilt **Land** world package (~2 GB) — the
terrain worlds (default, desert, forest, island, mountains) that ROSflight's
HoloOcean scenarios fly UAVs in. Only ROSflight-compatible worlds are
downloaded; the underwater **Ocean** package is opt-in
(`HOLOOCEAN_PACKAGE="Land Ocean" bash scripts/setup_holoocean.sh`).
(It has to work this way: multi-GB downloads shouldn't block `workspace up`,
and the gated HoloOcean clone needs your VS Code GitHub sign-in, which only
becomes available once the VS Code window attaches — see Authentication.)

So right after the window opens, ROS packages and HoloOcean may not exist
*yet*. Check progress inside the container with:

```bash
setup-status                          # phase summary (alias in ~/.bashrc)
tail -f log/setup/setup_all.log       # full live log
```

If the background setup is interrupted (container stopped mid-download, host
shut down, a download failed), it resumes automatically on the next container
start (`postStartCommand` relaunches any unfinished phase; finished phases are
never redone). You can also run `bash scripts/setup_all.sh` manually at any
time — it is idempotent and self-locking.

If you prefer plain Docker/VS Code, this is a standard devcontainer — "Reopen in
Container" from VS Code works too.

To skip the multi-GB world download at create time (fetch it later by
re-running `bash scripts/setup_holoocean.sh` without the variable):

```bash
devsy workspace up . --ide vscode --init-env HOLOOCEAN_SKIP_WORLDS=1
```

## Running a simulation

From the workspace root (open a fresh shell so ROS is sourced, or
`source install/setup.bash`):

```bash
# ROSflight sims
ros2 launch rosflight_sim multirotor_standalone.launch.py             # RViz standalone
ros2 launch rosflight_sim fixedwing_standalone.launch.py use_vimfly:=true

ros2 launch rosplane_sim sim.launch.py     # ROSplane (fixed-wing)
ros2 launch roscopter_sim sim.launch.py    # ROScopter (multirotor)
```

ROSflight UAVs flying in HoloOcean worlds:

```bash
ros2 launch rosflight_sim multirotor_holoocean.launch.py    # env:=default|desert|forest|island|mountains
ros2 launch rosflight_sim fixedwing_holoocean.launch.py
```

HoloOcean smoke test (opens a world window):

```bash
python3 -c "import holoocean; env = holoocean.make('default_multirotor'); [env.tick() for _ in range(300)]"
```

HoloOcean scenarios, sensors, and the ROS 2 interface are documented at
<https://byu-holoocean.github.io/holoocean-docs/>. The cloned source lives in
`holoocean/` at the workspace root.

If GUI windows don't appear, run the following on the **host computer** (not in
the Devsy workspace): `xhost +local:docker`. To check that the GPU made it
into the container, run `nvidia-smi` and `vulkaninfo --summary` inside it.

## Troubleshooting

Frankly, just ask any capable AI agent for help. As of 2026 this will probably
be more effective than outdated instructions in this README.md.

You can point your AI agent to the instructions on the
[ROSflight website](https://docs.rosflight.org/latest/user-guide/overview/) and
the [HoloOcean docs](https://byu-holoocean.github.io/holoocean-docs/) for
context.

Common first-run failures:

- **`import holoocean` fails or `ros2 launch` can't find packages right after
  the first launch** — the background setup is probably still running (the
  Land world package is ~2 GB). Run `setup-status` (or
  `bash scripts/setup_all.sh --status`) and wait for both phases to report
  `done`. If a phase reports a failure in the log, fix the cause (usually
  network or GitHub auth) and either restart the container or run
  `bash scripts/setup_all.sh` — completed phases are skipped.
- **Workspace startup dies with a Go panic (`tunnelserver.GitCredentials ...
  nil pointer dereference`)** — a bug in the unmaintained DevPod: its
  injected git credential helper crashes the host agent when the container
  asks for git credentials during postCreate. `scripts/setup_holoocean.sh`
  strips helpers naming `devpod` from its clone (Devsy's maintained helper is
  kept), so with a current copy of the script this shouldn't occur under
  either tool. `HOLOOCEAN_USE_DEFAULT_GIT_HELPERS=1` opts back in to using
  all configured helpers as-is.
- **HoloOcean clone fails or keeps waiting for credentials**
  (`terminal prompts disabled` / `Repository not found` / "No GitHub
  credential source is visible" in `log/setup/setup_all.log`) — the repo is
  Epic-gated and the container found no usable GitHub credentials. Opening
  the workspace window in VS Code (signed in to GitHub with the Epic-linked
  account) is normally enough; otherwise give the container credentials of
  its own:

  ```bash
  gh auth login          # authenticate the GitHub CLI (device-code flow)
  bash scripts/setup_holoocean.sh
  ```

  If it still fails, step 1 of
  [Authentication](#authentication-one-time-before-first-launch) (the
  GitHub↔Epic link) was skipped. If your account was migrated to Epic's mirror organization, re-run
  with `HOLOOCEAN_REPO_URL=https://github.com/byu-holoocean-mirror/HoloOcean.git bash scripts/setup_holoocean.sh`.
- **World window never opens / Vulkan errors** — the NVIDIA Container Toolkit
  isn't installed on the host, or the Devsy provider dropped `--gpus=all`.

## Changing the ROS distribution

Edit the build arg in
[`.devcontainer/devcontainer.json`](.devcontainer/devcontainer.json):

```jsonc
"build": { "dockerfile": "Dockerfile", "args": { "ROS_DISTRO": "humble" } }
```

Set it to `jazzy` for ROS 2 Jazzy (Ubuntu 24.04), then rebuild the container.
As in the reference template, the `osrf/ros` base guarantees the Ubuntu
release matches the distro.

## Licensing notes

- The image built from this Dockerfile contains no Unreal Engine code, so
  the image itself is not EULA-encumbered. The HoloOcean source cloned into
  `holoocean/` and the downloaded world binaries **are** governed by the
  [Unreal Engine EULA](https://www.unrealengine.com/eula) and HoloOcean's own
  license: do not commit them here, do not rehost the world packages, and do
  not push a container image with the worlds baked in to a public registry.
- The "Unreal runtime dependencies" layer in the Dockerfile is adapted from
  [adamrehn/ue4-runtime](https://github.com/adamrehn/ue4-runtime)
  (MIT License, Copyright (c) Adam Rehn) and NVIDIA's public glvnd runtime
  image definitions.
- This repository itself (the Dockerfile, scripts, and docs) is BSD-3-Clause
  and contains nothing Epic- or BYU-derived.

## Additional included features

- **Claude Code** and the **Codex CLI**
  - Run `claude` or `codex` to launch these.
- **uv**, plus a uv-managed **Python 3.12**
- **Rust** (rustup, stable toolchain)
- **tmux** and **Zellij**

## Layout

```
.
├── .devcontainer/   # Dockerfile, devcontainer.json, setup.sh, .bash_aliases
├── .claude/         # Claude Code settings (bypassPermissions)
├── scripts/         # setup_all.sh (background orchestrator), ensure_setup.sh (relauncher),
│                    # setup_workspace.sh, setup_holoocean.sh
├── log/setup/       # background-setup log + phase completion markers (gitignored)
├── src/             # ROSflight repos (cloned by the setup script; gitignored)
├── holoocean/       # HoloOcean repo (cloned by the setup script; gitignored)
├── AGENTS.md        # guidance for AI coding agents
└── CLAUDE.md        # imports AGENTS.md
```
