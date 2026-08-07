# ROSflight + HoloOcean Devcontainer

A [devcontainer](https://containers.dev/) for running ROSflight simulations in the [HoloOcean](https://byu-holoocean.github.io/holoocean-docs/) simulator.

This repo contains **no Unreal Engine or HoloOcean code or binaries** — only
build recipes. Licensed material is pulled at build/setup time using your Epic Games credentials. See [Licensing notes](#licensing-notes).

The devcontainer in this repo only supports running existing HoloOcean worlds. It does **NOT** support building and developing new worlds. 

## Prerequisites

> [!IMPORTANT]  
> **You must have an Epic Games account linked to GitHub for this container to work.**
> Follow the [official instructions](https://www.unrealengine.com/ue-on-github) before attempting the rest of the setup.


> [!IMPORTANT]  
> **You must have an NVIDIA GPU capable of running the Unreal Engine.**
> This is required by HoloOcean.

Install the following:

- [Docker](https://docs.docker.com/get-docker/)
- A devcontainer manager such as [Devsy](https://devsy.sh/docs/getting-started/install) (CLI or desktop app)
- The [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
- An X11 server on the host (standard on Linux) for GUI sim tools

The remainder of these instructions will assume you are using the [Devsy CLI](https://devsy.sh/docs/getting-started/install#install-devsy-cli) in an Ubuntu Linux environment.

Add Docker as a provider the first time you install Devsy:

```bash
devsy provider add docker
```

## Quick start

Run the following from the project's root directory:

```bash
devsy workspace up . --ide vscode
```

This will launch a VSCode window that is ssh'ed into a Docker container with
ROSflight, ROS2, and HoloOcean installed. 

The first time this is launched, the container will automatically do the following:

* Clone + build the ROS workspace
* Clone HoloOcean + download prebuilt "Land" world package (~2GB)

**This may take some time to complete.** Be patient. You can check progress inside the container with:

```bash
setup-status                          # phase summary (alias in ~/.bashrc)
tail -f log/setup/setup_all.log       # full live log
```

To skip the multi-GB world download at create time, launch the container with:

```bash
devsy workspace up . --ide vscode --init-env HOLOOCEAN_SKIP_WORLDS=1
```

You can fetch it later by
re-running `bash scripts/setup_holoocean.sh`.

## Running a simulation

To run simulations with HoloOcean, open a fresh shell and run one of the following example commands.
The `env:=...` variable chooses the environment the UAV is flown in.

```bash
ros2 launch rosflight_sim multirotor_holoocean.launch.py    # env:=default|desert|forest|island|mountains
ros2 launch rosflight_sim fixedwing_holoocean.launch.py
```



To fly ROSflight in an RViz window without HoloOcean, use one of the following example commands:

```bash
# ROSflight sims
ros2 launch rosflight_sim multirotor_standalone.launch.py             # RViz standalone
ros2 launch rosflight_sim fixedwing_standalone.launch.py use_vimfly:=true

ros2 launch rosplane_sim sim.launch.py     # ROSplane (fixed-wing)
ros2 launch roscopter_sim sim.launch.py    # ROScopter (multirotor)
```

HoloOcean scenarios, sensors, and the ROS 2 interface are documented at
<https://byu-holoocean.github.io/holoocean-docs/>. The cloned source lives in
`holoocean/` at the workspace root.


## Changing the ROS distribution

Edit the build arg in
[`.devcontainer/devcontainer.json`](.devcontainer/devcontainer.json):

```jsonc
"build": { "dockerfile": "Dockerfile", "args": { "ROS_DISTRO": "humble" } }
```

Set it to `jazzy` for ROS 2 Jazzy (Ubuntu 24.04), then rebuild the container.
As in the reference template, the `osrf/ros` base guarantees the Ubuntu
release matches the distro.

## Troubleshooting

We recommend using a capable AI agent to help debug issues. You can point your AI agent to the instructions on the
[ROSflight website](https://docs.rosflight.org/latest/user-guide/overview/) and
the [HoloOcean docs](https://byu-holoocean.github.io/holoocean-docs/) for
context.

Common first-run failures:

- **No GUI windows appear.** If GUI windows don't show up, run the following on the **host computer** (not in
the devcontainer): `xhost +local:docker`. To check that the GPU made it
into the container, run `nvidia-smi` and `vulkaninfo --summary` inside it.
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




## Licensing notes

- The image built from this Dockerfile contains no Unreal Engine or HoloOcean code. The HoloOcean source cloned into
  `holoocean/` and the downloaded world binaries are governed by the
  [Unreal Engine EULA](https://www.unrealengine.com/eula) and HoloOcean's own
  license. **Do not push any of these elements to a public registry after the container is created.**
- The "Unreal runtime dependencies" layer in the Dockerfile is adapted from
  [adamrehn/ue4-runtime](https://github.com/adamrehn/ue4-runtime)
  (MIT License, Copyright (c) Adam Rehn) and NVIDIA's public glvnd runtime
  image definitions.
- Everything else in this repository itself (scripts, docs, etc.) is MIT Licensed.

## Additional included features

- **Claude Code** and the **Codex CLI**
  - Run `claude` or `codex` to launch these.
- **uv**, plus a uv-managed **Python 3.12**
- **Rust** (rustup, stable toolchain)
- **tmux** and **Zellij**