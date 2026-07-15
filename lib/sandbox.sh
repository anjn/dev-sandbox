#!/usr/bin/env bash

SANDBOX_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[1]}")" && pwd -P)
WORKSPACE_DIR=$(readlink -f -- "$PWD")
WORKSPACE_NAME=$(basename -- "$WORKSPACE_DIR")
CONTAINER_NAME="dev-sandbox-$WORKSPACE_NAME"
SANDBOX_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/dev-sandbox"
SANDBOX_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dev-sandbox"
SSH_AUTHORIZED_KEYS_FILE="${SANDBOX_SSH_AUTHORIZED_KEYS_FILE:-$SANDBOX_CONFIG_DIR/authorized_keys}"
SSH_IDENTITY_FILE="${SANDBOX_SSH_IDENTITY_FILE:-~/.ssh/dev-sandbox}"
SSH_PORT_STATE_FILE="$SANDBOX_STATE_DIR/$CONTAINER_NAME.ssh-port"
SSH_PORT="${SANDBOX_SSH_PORT:-}"
SSH_PORT_MIN=22000
SSH_PORT_MAX=22999

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

sandbox_validate_ssh_port() {
    local port=$1

    [[ $port =~ ^[0-9]+$ ]] && ((port >= 1024 && port <= 65535))
}

sandbox_read_ssh_port() {
    local port

    [[ -f $SSH_PORT_STATE_FILE ]] || return 1
    IFS= read -r port < "$SSH_PORT_STATE_FILE"
    sandbox_validate_ssh_port "$port" || return 1
    printf '%s\n' "$port"
}

sandbox_running_ssh_port() {
    local port

    command -v podman >/dev/null 2>&1 || return 1
    podman container exists "$CONTAINER_NAME" >/dev/null 2>&1 || return 1
    [[ $(podman inspect --format '{{.State.Running}}' "$CONTAINER_NAME") == true ]] || return 1

    port=$(podman inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_NAME" |
        sed -n 's/^SANDBOX_SSH_PORT=//p' | head -n 1)
    sandbox_validate_ssh_port "$port" || return 1
    printf '%s\n' "$port"
}

sandbox_ssh_port_in_use() {
    local port=$1

    ss -H -ltn | awk -v suffix=":$port" '
        {
            address = $4
            if (length(address) >= length(suffix) &&
                substr(address, length(address) - length(suffix) + 1) == suffix) {
                found = 1
            }
        }
        END { exit(found ? 0 : 1) }
    '
}

sandbox_ssh_port_reserved() {
    local port=$1
    local reservation_file
    local reserved_port

    for reservation_file in "$SANDBOX_STATE_DIR"/*.ssh-port; do
        [[ -e $reservation_file ]] || continue
        [[ $reservation_file == "$SSH_PORT_STATE_FILE" ]] && continue
        IFS= read -r reserved_port < "$reservation_file" || continue
        if sandbox_validate_ssh_port "$reserved_port" && [[ $reserved_port == "$port" ]]; then
            return 0
        fi
    done
    return 1
}

sandbox_write_ssh_port() {
    local port=$1
    local temporary_file="$SSH_PORT_STATE_FILE.$$"

    umask 077
    printf '%s\n' "$port" > "$temporary_file"
    mv -f -- "$temporary_file" "$SSH_PORT_STATE_FILE"
}

sandbox_allocate_ssh_port() (
    local lock_fd
    local port
    local running_port=""
    local saved_port=""

    install -d -m 0700 -- "$SANDBOX_STATE_DIR"
    exec {lock_fd}>"$SANDBOX_STATE_DIR/ssh-port.lock"
    flock "$lock_fd"

    running_port=$(sandbox_running_ssh_port 2>/dev/null || true)

    if [[ -n ${SANDBOX_SSH_PORT:-} ]]; then
        sandbox_validate_ssh_port "$SANDBOX_SSH_PORT" || {
            echo "Invalid SANDBOX_SSH_PORT: $SANDBOX_SSH_PORT (expected 1024-65535)" >&2
            return 1
        }
        if [[ $SANDBOX_SSH_PORT != "$running_port" ]]; then
            if sandbox_ssh_port_in_use "$SANDBOX_SSH_PORT"; then
                echo "SSH port is already in use: $SANDBOX_SSH_PORT" >&2
                return 1
            fi
            if sandbox_ssh_port_reserved "$SANDBOX_SSH_PORT"; then
                echo "SSH port is reserved by another workspace: $SANDBOX_SSH_PORT" >&2
                return 1
            fi
        fi
        sandbox_write_ssh_port "$SANDBOX_SSH_PORT"
        printf '%s\n' "$SANDBOX_SSH_PORT"
        return
    fi

    if [[ -n $running_port ]]; then
        sandbox_write_ssh_port "$running_port"
        printf '%s\n' "$running_port"
        return
    fi

    saved_port=$(sandbox_read_ssh_port 2>/dev/null || true)
    if [[ -n $saved_port ]] && ! sandbox_ssh_port_in_use "$saved_port" &&
        ! sandbox_ssh_port_reserved "$saved_port"; then
        printf '%s\n' "$saved_port"
        return
    fi

    for ((port = SSH_PORT_MIN; port <= SSH_PORT_MAX; port++)); do
        if ! sandbox_ssh_port_in_use "$port" && ! sandbox_ssh_port_reserved "$port"; then
            sandbox_write_ssh_port "$port"
            printf '%s\n' "$port"
            return
        fi
    done

    echo "No free SSH port found in range $SSH_PORT_MIN-$SSH_PORT_MAX." >&2
    echo "Set SANDBOX_SSH_PORT to an unused port between 1024 and 65535." >&2
    return 1
)

sandbox_prepare_ssh_port() {
    SSH_PORT=$(sandbox_allocate_ssh_port)
}

sandbox_load_ssh_port() {
    local port

    if [[ -n ${SANDBOX_SSH_PORT:-} ]]; then
        sandbox_validate_ssh_port "$SANDBOX_SSH_PORT" || return 1
        SSH_PORT=$SANDBOX_SSH_PORT
        return
    fi

    port=$(sandbox_running_ssh_port 2>/dev/null || sandbox_read_ssh_port 2>/dev/null || true)
    [[ -n $port ]] || return 1
    SSH_PORT=$port
}

sandbox_check_ssh_authorized_keys() {
    local owner
    local permissions

    if [[ ! -f $SSH_AUTHORIZED_KEYS_FILE || ! -s $SSH_AUTHORIZED_KEYS_FILE ]]; then
        cat >&2 <<EOF
No SSH public key is registered for dev-sandbox.
Add a key and retry ./up:

  $SANDBOX_DIR/add-ssh-key ~/.ssh/dev-sandbox.pub

Keys are stored in:
  $SSH_AUTHORIZED_KEYS_FILE
EOF
        return 1
    fi

    if ! ssh-keygen -l -f "$SSH_AUTHORIZED_KEYS_FILE" >/dev/null 2>&1; then
        echo "No valid SSH public key found in: $SSH_AUTHORIZED_KEYS_FILE" >&2
        return 1
    fi

    owner=$(stat -c '%u' "$SSH_AUTHORIZED_KEYS_FILE")
    if [[ $owner != "$(id -u)" ]]; then
        echo "SSH authorized_keys must be owned by the current user: $SSH_AUTHORIZED_KEYS_FILE" >&2
        return 1
    fi

    permissions=$(stat -c '%a' "$SSH_AUTHORIZED_KEYS_FILE")
    if ((((8#$permissions)) & 0022)); then
        echo "SSH authorized_keys must not be writable by group or others: $SSH_AUTHORIZED_KEYS_FILE" >&2
        echo "Run: chmod 600 '$SSH_AUTHORIZED_KEYS_FILE'" >&2
        return 1
    fi
}

sandbox_default_ssh_host() {
    hostname -f 2>/dev/null || hostname
}

sandbox_print_ssh_info() {
    local host=${1:-${SANDBOX_SSH_HOST:-$(sandbox_default_ssh_host)}}

    [[ -n $SSH_PORT ]] || sandbox_load_ssh_port || {
        echo "SSH port is not assigned. Run ./up first." >&2
        return 1
    }

    cat <<EOF
SSH connection:
  ssh -i $SSH_IDENTITY_FILE -p $SSH_PORT ubuntu@$host

OpenSSH config for VS Code Remote SSH:
  Host $CONTAINER_NAME
    HostName $host
    User ubuntu
    Port $SSH_PORT
    IdentityFile $SSH_IDENTITY_FILE
    IdentitiesOnly yes
EOF
}

sandbox_compose() {
    local platform=$1
    shift

    (
        cd -- "$SANDBOX_DIR"
        CONTAINER_NAME="$CONTAINER_NAME" \
        WORKSPACE_DIR="$WORKSPACE_DIR" \
        SANDBOX_SSH_PORT="${SSH_PORT:-2222}" \
        SANDBOX_SSH_AUTHORIZED_KEYS_FILE="$SSH_AUTHORIZED_KEYS_FILE" \
        podman-compose \
            --file compose.yaml \
            --file "compose.$platform.yaml" \
            --project-name "$CONTAINER_NAME" \
            "$@"
    )
}
