#!/usr/bin/env bash

# Keep the setup script and the up preflight check on the same device list.
RW_DEVICES=(
    /dev/nvmap
    /dev/nvhost-as-gpu
    /dev/nvhost-ctrl-gpu
    /dev/nvhost-gpu
    /dev/nvhost-nvsched-gpu
    /dev/nvhost-power-gpu
    /dev/nvhost-tsg-gpu
    /dev/nvgpu/igpu0/as
    /dev/nvgpu/igpu0/channel
    /dev/nvgpu/igpu0/ctrl
    /dev/nvgpu/igpu0/power
    /dev/nvgpu/igpu0/tsg
    /dev/dri/renderD128
    /dev/dri/renderD129
)
READ_DEVICES=(
    /dev/nvgpu/igpu0/nvsched
)
