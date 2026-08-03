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
UP_HELP_REQUESTED=0
SANDBOX_DISPLAY_ENABLED=0
SANDBOX_XAUTHORITY_FILE=""
SANDBOX_AUTOWARE_DATA_DIR=""
EXTRA_MOUNT_SOURCES=()
EXTRA_MOUNT_TARGETS=()
EXTRA_MOUNT_MODES=()

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

sandbox_resolve_role() {
    case "${SANDBOX_ROLE:-base}" in
        base|ros2-tools)
            printf '%s\n' "${SANDBOX_ROLE:-base}"
            ;;
        *)
            echo "Invalid SANDBOX_ROLE: $SANDBOX_ROLE (expected base or ros2-tools)" >&2
            return 1
            ;;
    esac
}

sandbox_check_role_platform() {
    local role=$1
    local platform=$2

    if [[ $role == ros2-tools && $platform != rocm ]]; then
        echo "SANDBOX_ROLE=ros2-tools is only supported with SANDBOX_PLATFORM=rocm." >&2
        return 1
    fi
}

sandbox_resolve_xauthority_file() {
    local candidate
    local -a candidates=()

    if [[ -n ${XAUTHORITY:-} ]]; then
        candidates+=("$XAUTHORITY")
    fi
    candidates+=("$HOME/.Xauthority")

    for candidate in "${candidates[@]}"; do
        if [[ -f $candidate ]]; then
            readlink -f -- "$candidate"
            return
        fi
    done

    if [[ -n ${XAUTHORITY:-} ]]; then
        echo "XAUTHORITY does not point to an existing file: $XAUTHORITY" >&2
    else
        echo "No Xauthority file found. Set XAUTHORITY or create $HOME/.Xauthority." >&2
    fi
    return 1
}

sandbox_prepare_display_environment() {
    local required=$1

    SANDBOX_DISPLAY_ENABLED=0
    SANDBOX_XAUTHORITY_FILE=/dev/null

    if [[ -z ${DISPLAY:-} ]]; then
        if [[ $required == required ]]; then
            echo "DISPLAY is required for SANDBOX_ROLE=ros2-tools." >&2
            return 1
        fi
        return
    fi

    if [[ ! -d /tmp/.X11-unix ]]; then
        if [[ $required == required ]]; then
            echo "X11 socket directory not found: /tmp/.X11-unix" >&2
            return 1
        fi
        return
    fi

    if SANDBOX_XAUTHORITY_FILE=$(sandbox_resolve_xauthority_file 2>/dev/null); then
        :
    elif [[ $required == required ]]; then
        sandbox_resolve_xauthority_file >/dev/null
        return 1
    else
        SANDBOX_XAUTHORITY_FILE=/dev/null
    fi

    SANDBOX_DISPLAY_ENABLED=1
}

sandbox_prepare_role_environment() {
    local role=$1

    case "$role" in
        base)
            sandbox_prepare_display_environment optional
            return
            ;;
        ros2-tools)
            sandbox_prepare_display_environment required || return
            SANDBOX_AUTOWARE_DATA_DIR=$(readlink -m -- "$HOME/autoware_data")
            [[ -d $SANDBOX_AUTOWARE_DATA_DIR ]] || {
                cat >&2 <<EOF
Autoware data directory not found: $SANDBOX_AUTOWARE_DATA_DIR
Create the CycloneDDS config before starting ros2-tools:

  mkdir -p "$HOME/autoware_data/config"
  $SANDBOX_DIR/scripts/make-cyclonedds-config --interface lo --output "$HOME/autoware_data/config/cyclonedds.xml"
EOF
                return 1
            }
            ;;
    esac
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

sandbox_print_up_usage() {
    cat <<EOF
Usage: $SANDBOX_DIR/up [-v HOST[:CONTAINER[:ro|rw]]]...

Add one or more directory bind mounts for this invocation of up.
If CONTAINER is omitted, the canonical HOST path is used in the container.
The default access mode is rw. Use HOST::ro for a read-only same-path mount.

Environment:
  SANDBOX_PLATFORM=rocm|jetson
  SANDBOX_ROLE=base|ros2-tools

Examples:
  $SANDBOX_DIR/up -v /data/models
  $SANDBOX_DIR/up -v /data/models:/models:ro
  $SANDBOX_DIR/up --volume=./cache:/cache:rw
EOF
}

sandbox_path_contains() {
    local parent=$1
    local child=$2

    [[ $child == "$parent" || $child == "$parent/"* ]]
}

sandbox_check_extra_mount_target() {
    local target=$1
    local existing_target
    local managed_target
    local protected_target

    for existing_target in "${EXTRA_MOUNT_TARGETS[@]}"; do
        if [[ $target == "$existing_target" ]]; then
            echo "Duplicate extra mount target: $target" >&2
            return 1
        fi
    done

    for managed_target in /workspace /home/ubuntu/.codex; do
        if sandbox_path_contains "$target" "$managed_target"; then
            echo "Extra mount target would hide a managed mount: $target" >&2
            return 1
        fi
    done

    for protected_target in \
        /etc/dev-sandbox/authorized_keys \
        /var/lib/dev-sandbox/ssh \
        /etc/ssh \
        /run/sshd \
        /usr/local/sbin/dev-sandbox-sshd; do
        if sandbox_path_contains "$target" "$protected_target" ||
            sandbox_path_contains "$protected_target" "$target"; then
            echo "Extra mount target conflicts with the SSH runtime: $target" >&2
            return 1
        fi
    done
}

sandbox_add_extra_mount() {
    local spec=$1
    local source
    local target
    local mode
    local remainder

    [[ -n $spec ]] || {
        echo "Volume specification must not be empty." >&2
        return 1
    }

    if [[ $spec == *:*:* ]]; then
        source=${spec%%:*}
        remainder=${spec#*:}
        target=${remainder%%:*}
        mode=${remainder#*:}
        if [[ $mode == *:* ]]; then
            echo "Paths containing ':' are not supported in volume specifications: $spec" >&2
            return 1
        fi
    elif [[ $spec == *:* ]]; then
        source=${spec%%:*}
        target=${spec#*:}
        mode=rw
    else
        source=$spec
        target=""
        mode=rw
    fi

    [[ -n $source ]] || {
        echo "Volume source must not be empty: $spec" >&2
        return 1
    }
    [[ -d $source ]] || {
        echo "Volume source is not an existing directory: $source" >&2
        return 1
    }
    source=$(readlink -f -- "$source")

    case "$mode" in
        ro|rw)
            ;;
        *)
            echo "Invalid volume mode '$mode' in: $spec (expected ro or rw)" >&2
            return 1
            ;;
    esac

    if [[ -z $target ]]; then
        target=$source
    elif [[ $target != /* ]]; then
        echo "Volume target must be an absolute path: $target" >&2
        return 1
    else
        target=$(readlink -m -- "$target")
    fi

    sandbox_check_extra_mount_target "$target" || return

    EXTRA_MOUNT_SOURCES+=("$source")
    EXTRA_MOUNT_TARGETS+=("$target")
    EXTRA_MOUNT_MODES+=("$mode")
}

sandbox_parse_up_args() {
    local argument

    UP_HELP_REQUESTED=0
    EXTRA_MOUNT_SOURCES=()
    EXTRA_MOUNT_TARGETS=()
    EXTRA_MOUNT_MODES=()

    while (($#)); do
        argument=$1
        case "$argument" in
            -v|--volume)
                shift
                (($#)) || {
                    echo "Missing volume specification after $argument." >&2
                    sandbox_print_up_usage >&2
                    return 1
                }
                sandbox_add_extra_mount "$1" || return
                ;;
            --volume=*)
                sandbox_add_extra_mount "${argument#*=}" || return
                ;;
            -h|--help)
                UP_HELP_REQUESTED=1
                sandbox_print_up_usage
                return
                ;;
            *)
                echo "Unknown up argument: $argument" >&2
                sandbox_print_up_usage >&2
                return 1
                ;;
        esac
        shift
    done
}

sandbox_render_extra_mounts() {
    local index
    local -a arguments=()

    for ((index = 0; index < ${#EXTRA_MOUNT_SOURCES[@]}; index++)); do
        arguments+=(
            "${EXTRA_MOUNT_SOURCES[index]}"
            "${EXTRA_MOUNT_TARGETS[index]}"
            "${EXTRA_MOUNT_MODES[index]}"
        )
    done

    python3 "$SANDBOX_DIR/lib/render-mounts.py" "${arguments[@]}"
}

sandbox_compose() {
    local platform=$1
    local role=$2
    local -a extra_files=()
    local -a compose_files=(--file compose.yaml)
    shift 2

    case "$role" in
        base)
            compose_files+=(--file "compose.$platform.yaml")
            if ((SANDBOX_DISPLAY_ENABLED)); then
                compose_files+=(--file compose.display.yaml)
            fi
            ;;
        ros2-tools)
            compose_files+=(--file compose.ros2-tools-amd.yaml)
            ;;
        *)
            echo "Invalid SANDBOX_ROLE: $role (expected base or ros2-tools)" >&2
            return 1
            ;;
    esac

    if [[ -n ${SANDBOX_COMPOSE_OVERRIDE_FILE:-} ]]; then
        extra_files=(--file "$SANDBOX_COMPOSE_OVERRIDE_FILE")
    fi

    (
        cd -- "$SANDBOX_DIR"
        CONTAINER_NAME="$CONTAINER_NAME" \
        WORKSPACE_DIR="$WORKSPACE_DIR" \
        SANDBOX_SSH_PORT="${SSH_PORT:-2222}" \
        SANDBOX_SSH_AUTHORIZED_KEYS_FILE="$SSH_AUTHORIZED_KEYS_FILE" \
        SANDBOX_XAUTHORITY_FILE="${SANDBOX_XAUTHORITY_FILE:-/dev/null}" \
        SANDBOX_AUTOWARE_DATA_DIR="${SANDBOX_AUTOWARE_DATA_DIR:-$HOME/autoware_data}" \
        DISPLAY="${DISPLAY:-}" \
        XDG_SESSION_TYPE="${XDG_SESSION_TYPE:-}" \
        ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-}" \
        podman-compose \
            "${compose_files[@]}" \
            "${extra_files[@]}" \
            --project-name "$CONTAINER_NAME" \
            "$@"
    )
}
