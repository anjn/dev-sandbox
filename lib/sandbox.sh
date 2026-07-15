#!/usr/bin/env bash

SANDBOX_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[1]}")" && pwd -P)
WORKSPACE_DIR=$(readlink -f -- "$PWD")
WORKSPACE_NAME=$(basename -- "$WORKSPACE_DIR")
CONTAINER_NAME="dev-sandbox-$WORKSPACE_NAME"

sandbox_require_commands() {
    local command_name

    for command_name in "$@"; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            echo "Required command not found: $command_name" >&2
            return 1
        fi
    done
}

sandbox_resolve_platform() {
    case "${SANDBOX_PLATFORM:-}" in
        rocm|jetson)
            printf '%s\n' "$SANDBOX_PLATFORM"
            return
            ;;
        "")
            ;;
        *)
            echo "Invalid SANDBOX_PLATFORM: $SANDBOX_PLATFORM (expected rocm or jetson)" >&2
            return 1
            ;;
    esac

    if [[ -e /etc/nv_tegra_release || $(uname -r) == *tegra* ]]; then
        printf '%s\n' jetson
    elif [[ -e /dev/kfd ]]; then
        printf '%s\n' rocm
    else
        echo "Unable to detect the accelerator platform. Set SANDBOX_PLATFORM=rocm or jetson." >&2
        return 1
    fi
}

sandbox_check_jetson_cdi() {
    sandbox_require_commands nvidia-ctk

    if nvidia-ctk cdi list 2>/dev/null | grep -Fqx 'nvidia.com/gpu=all'; then
        return
    fi

    cat >&2 <<'EOF'
The Jetson GPU CDI device nvidia.com/gpu=all is not registered.
Run the following one-time host setup, then retry ./up:

  sudo install -d -m 0755 /etc/cdi
  sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
  nvidia-ctk cdi list
EOF
    return 1
}

sandbox_compose() {
    local platform=$1
    shift

    (
        cd -- "$SANDBOX_DIR"
        CONTAINER_NAME="$CONTAINER_NAME" \
        WORKSPACE_DIR="$WORKSPACE_DIR" \
        podman-compose \
            --file compose.yaml \
            --file "compose.$platform.yaml" \
            --project-name "$CONTAINER_NAME" \
            "$@"
    )
}
