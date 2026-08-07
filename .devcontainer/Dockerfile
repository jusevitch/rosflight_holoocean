# ROSflight + HoloOcean simulation devcontainer.
#
# Uses the same base image as the official ROSflight Docker setup
# (osrf/ros:${ROS_DISTRO}-desktop), like the jusevitch/rosflight_devpod
# reference template, and adds the runtime dependencies that packaged Unreal
# Engine projects (the prebuilt HoloOcean worlds) need.
#
# WHY NOT THE OFFICIAL UNREAL RUNTIME IMAGE? Epic's prebuilt runtime image
# (ghcr.io/epicgames/unreal-engine:runtime) is built on Ubuntu 20.04 (focal),
# which cannot host ROS 2 Humble or Jazzy. Epic versions its dev images
# (dev-5.3 ... dev-slim-5.8.1) but not its runtime images: probing 2026-08
# found no runtime-5.3/5.4/5.5/5.6/5.7/5.8/5.8.1 tags -- the unversioned,
# focal-based "runtime" tag is the only one published. The runtime image contains NO Unreal Engine code -- it is plain
# Ubuntu plus a graphics/Vulkan userspace -- so nothing license-relevant is
# lost by replicating that userspace here instead. The "Unreal runtime
# dependencies" layer below is adapted from the open-source projects the
# official image is derived from:
#   * adamrehn/ue4-runtime (MIT License, Copyright (c) Adam Rehn)
#     https://github.com/adamrehn/ue4-runtime
#   * nvidia/container-images/opengl (glvnd runtime layer)
#     https://gitlab.com/nvidia/container-images/opengl
#
# The ROS distro is configurable via the ROS_DISTRO build arg (set it in
# .devcontainer/devcontainer.json). Default is Humble.
#
# This Dockerfile only installs system/ROS tooling and creates the user. The AI
# coding agents (Claude Code, Codex), the ROS workspace build, and the
# HoloOcean install happen at container-create time in .devcontainer/setup.sh,
# because the workspace source is bind-mounted (and HoloOcean's repo needs your
# personal Epic-linked GitHub credentials) and neither is available during the
# image build.

ARG ROS_DISTRO=humble
FROM osrf/ros:${ROS_DISTRO}-desktop

# Re-declare after FROM so the value is available in later layers, and export it
# as an env var so setup.sh / setup_workspace.sh can read $ROS_DISTRO.
ARG ROS_DISTRO=humble
ENV ROS_DISTRO=${ROS_DISTRO}
ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-c"]

ARG USERNAME=rosflight
ARG USER_UID=1000
ARG USER_GID=1000

# System + ROS dev tools. Mirrors the ROSflight docker image
# (ros-dev-tools, plotjuggler, zsh, vim) and adds the reference template's
# developer conveniences (git, curl, tmux, ripgrep, ...), plus
# python3-pip/venv for the HoloOcean client and vulkan-tools for `vulkaninfo`
# GPU debugging.
RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends \
        ros-dev-tools \
        ros-${ROS_DISTRO}-plotjuggler-ros \
        python3-pip \
        python3-venv \
        vulkan-tools \
        git \
        curl \
        wget \
        sudo \
        zsh \
        vim \
        tmux \
        ripgrep \
        unzip \
        ca-certificates \
        locales \
    && rm -rf /var/lib/apt/lists/*

# --- Unreal runtime dependencies ---------------------------------------------
# Replicates the userspace of the official Unreal runtime container image
# (ghcr.io/epicgames/unreal-engine:runtime) on this newer Ubuntu base, so the
# prebuilt HoloOcean world binaries can render. Adapted from
# adamrehn/ue4-runtime (MIT) and NVIDIA's glvnd runtime image; see header.
#
# 1. OpenGL/EGL via glvnd (the nvidia/opengl:*-glvnd-runtime layer), with the
#    NVIDIA EGL vendor file so EGL dispatch finds the injected driver.
# 2. Vulkan loader + an NVIDIA ICD manifest pointing at the driver library the
#    NVIDIA Container Toolkit injects at run time (api_version taken from the
#    installed loader, matching ue4-runtime's approach).
# 3. xdg-user-dirs, which the Unreal Engine uses to locate the user's
#    Documents directory.
# 4. The X11 runtime libraries from ue4-runtime's x11 variant, so world
#    windows can display on the host's X server.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libglvnd0 \
        libgl1 \
        libglx0 \
        libegl1 \
        libgles2 \
        libvulkan1 \
        xdg-user-dirs \
        libfontconfig1 \
        libfreetype6 \
        libglu1 \
        libsm6 \
        libxcomposite1 \
        libxcursor1 \
        libxdamage1 \
        libxi6 \
        libxkbcommon-x11-0 \
        libxrandr2 \
        libxrender1 \
        libxss1 \
        libxtst6 \
        libxv1 \
        x11-xkb-utils \
        xauth \
        xfonts-base \
        xkb-data \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /usr/share/glvnd/egl_vendor.d \
    && echo '{ "file_format_version" : "1.0.0", "ICD" : { "library_path" : "libEGL_nvidia.so.0" } }' \
        > /usr/share/glvnd/egl_vendor.d/10_nvidia.json \
    && VULKAN_API_VERSION="$(dpkg -s libvulkan1 | grep -oP 'Version: [0-9|\.]+' | grep -oP '[0-9|\.]+')" \
    && mkdir -p /etc/vulkan/icd.d \
    && printf '{\n    "file_format_version" : "1.0.0",\n    "ICD": {\n        "library_path": "libGLX_nvidia.so.0",\n        "api_version" : "%s"\n    }\n}\n' "${VULKAN_API_VERSION}" \
        > /etc/vulkan/icd.d/nvidia_icd.json

# NVIDIA Container Toolkit capabilities the Unreal runtime needs: graphics +
# display for onscreen/X11 rendering, compute because some engine versions
# unconditionally dlopen libcuda.so.1 before initialising the Vulkan RHI, and
# video for NVENC-dependent plugins. (devcontainer.json also sets
# NVIDIA_DRIVER_CAPABILITIES=all; this is the belt to that suspenders for
# anyone running the image outside the devcontainer.)
ENV NVIDIA_DRIVER_CAPABILITIES=all
ENV NVIDIA_VISIBLE_DEVICES=all

# Non-root user matching the ROSflight conventions (bash login shell; zsh is
# still installed and usable, it is just not the default. dialout/plugdev for
# USB flight-controller access; audio/video groups per ue4-runtime, since the
# Unreal Engine refuses to run as root under Linux). Passwordless sudo so
# setup.sh can run rosdep/apt at container-create time. If the base image ever
# ships a UID-1000 user, rename it instead of colliding.
RUN set -e; \
    if existing_user="$(getent passwd ${USER_UID} | cut -d: -f1)" && [ -n "${existing_user}" ]; then \
        if [ "${existing_user}" != "${USERNAME}" ]; then \
            existing_group="$(id -gn "${existing_user}")"; \
            usermod --login ${USERNAME} --home /home/${USERNAME} --move-home "${existing_user}"; \
            if [ "${existing_group}" != "${USERNAME}" ] && getent group "${existing_group}" >/dev/null; then \
                groupmod --new-name ${USERNAME} "${existing_group}"; \
            fi; \
        fi; \
    else \
        groupadd --gid ${USER_GID} ${USERNAME}; \
        useradd --uid ${USER_UID} --gid ${USER_GID} --create-home --shell /bin/bash ${USERNAME}; \
    fi; \
    usermod --shell /bin/bash ${USERNAME}; \
    usermod -aG sudo,dialout,plugdev,audio,video ${USERNAME}; \
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME}; \
    chmod 0440 /etc/sudoers.d/${USERNAME}

# The runtime user is selected by "remoteUser" in devcontainer.json. The image
# is intentionally left as root here so devcontainer features (node, github-cli)
# install cleanly on top of this image.
