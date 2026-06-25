FROM docker.io/rocm/pytorch:rocm7.2.2_ubuntu24.04_py3.12_pytorch_release_2.10.0

USER root

# Timezone
ENV TZ=Asia/Tokyo
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y sudo && \
    usermod -aG sudo ubuntu && \
    echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ubuntu && \
    chmod 0440 /etc/sudoers.d/ubuntu && \
    rm -rf /var/lib/apt/lists/*

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
    alsa-utils \
    build-essential \
    cmake \
    ffmpeg \
    gdb \
    jq \
    libasound2-dev \
    locales \
    nodejs \
    npm \
    pkg-config \
    portaudio19-dev \
    ripgrep \
    tmux \
    tree \
    unzip \
    vulkan-tools libvulkan1 mesa-vulkan-drivers \
    libdw1t64 python3-yaml \
    && rm -rf /var/lib/apt/lists/*

RUN locale-gen ja_JP.UTF-8 && update-locale LANG=ja_JP.UTF-8

RUN npm install n -g
RUN n stable
RUN apt purge -y nodejs npm
RUN apt autoremove -y

RUN npm install -g @openai/codex

USER ubuntu

RUN curl -fsSL https://astral.sh/uv/install.sh | sh
RUN curl -fsSL https://bun.sh/install | bash

RUN curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash
RUN curl -fsSL https://opencode.ai/install | bash
RUN curl -fsSL https://claude.ai/install.sh | bash

