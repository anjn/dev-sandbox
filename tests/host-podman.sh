#!/usr/bin/env bash

set -euo pipefail

REPOSITORY_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
cd -- "$REPOSITORY_DIR"
TEST_ROOT=$(mktemp -d)
SOCKET_PID=""

cleanup() {
    if [[ -n $SOCKET_PID ]]; then
        kill "$SOCKET_PID" 2>/dev/null || true
        wait "$SOCKET_PID" 2>/dev/null || true
    fi
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

FAKE_PODMAN_DATA="$TEST_ROOT/podman"
TEST_RUNTIME_DIR="$TEST_ROOT/runtime"
TEST_STATE_HOME="$TEST_ROOT/state"
SOCKET_PATH="$TEST_RUNTIME_DIR/podman/podman.sock"
ORIGINAL_PATH=$PATH
export FAKE_PODMAN_DATA
mkdir -p -- "$FAKE_PODMAN_DATA" "$(dirname -- "$SOCKET_PATH")" "$TEST_STATE_HOME"

python3 - "$SOCKET_PATH" <<'PY' &
import socket
import sys

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sys.argv[1])
server.listen()
while True:
    connection, _ = server.accept()
    connection.close()
PY
SOCKET_PID=$!
for _ in {1..50}; do
    [[ -S $SOCKET_PATH ]] && break
    sleep 0.02
done
[[ -S $SOCKET_PATH ]]

source "$REPOSITORY_DIR/lib/sandbox.sh"
SANDBOX_DIR=$REPOSITORY_DIR

SANDBOX_HOST_PODMAN=0
sandbox_prepare_host_podman
[[ $SANDBOX_HOST_PODMAN_ENABLED == 0 ]]

SANDBOX_HOST_PODMAN=invalid
if sandbox_prepare_host_podman >/dev/null 2>&1; then
    echo "Invalid SANDBOX_HOST_PODMAN should fail" >&2
    exit 1
fi

PATH="$REPOSITORY_DIR/tests/fake-bin:$ORIGINAL_PATH"
XDG_RUNTIME_DIR="$TEST_ROOT/missing-runtime"
SANDBOX_HOST_PODMAN=1
export PATH XDG_RUNTIME_DIR SANDBOX_HOST_PODMAN
missing_socket_error=$TEST_ROOT/missing-socket.error
if sandbox_prepare_host_podman 2>"$missing_socket_error"; then
    echo "A missing host Podman socket should fail preflight" >&2
    exit 1
fi
grep -Fq -- "systemctl --user enable --now podman.socket" "$missing_socket_error"

XDG_RUNTIME_DIR=$TEST_RUNTIME_DIR
export XDG_RUNTIME_DIR
sandbox_prepare_host_podman
[[ $SANDBOX_HOST_PODMAN_ENABLED == 1 ]]
[[ $SANDBOX_HOST_PODMAN_SOCKET == "$SOCKET_PATH" ]]
grep -Fq -- "--url unix://$SOCKET_PATH info" "$FAKE_PODMAN_DATA/remote.log"

FAKE_PODMAN_REMOTE_FAIL=1
export FAKE_PODMAN_REMOTE_FAIL
if sandbox_prepare_host_podman >/dev/null 2>&1; then
    echo "Host Podman API failure should fail preflight" >&2
    exit 1
fi
unset FAKE_PODMAN_REMOTE_FAIL

PATH=$ORIGINAL_PATH
export PATH
for compose_file in compose.rocm.yaml compose.jetson.yaml compose.ros2-tools-amd.yaml compose.ros2-rocm-amd.yaml; do
    config_output=$(
        CONTAINER_NAME=dev-sandbox-check \
        WORKSPACE_DIR=/host/workspace \
        SANDBOX_SSH_PORT=22999 \
        SANDBOX_SSH_AUTHORIZED_KEYS_FILE=/tmp/authorized_keys \
        SANDBOX_XAUTHORITY_FILE=/dev/null \
        SANDBOX_HOST_PODMAN_SOCKET="$SOCKET_PATH" \
        podman-compose \
            --file compose.yaml \
            --file "$compose_file" \
            --file compose.host-podman.yaml \
            --project-name dev-sandbox-check \
            config 2>/dev/null
    )
    [[ $config_output == *"$SOCKET_PATH:/run/podman/podman.sock"* ]]
    [[ $config_output == *"CONTAINER_HOST: unix:///run/podman/podman.sock"* ]]
    [[ $config_output == *"SANDBOX_HOST_WORKSPACE: /host/workspace"* ]]
    [[ $config_output == *"io.github.anjn.dev-sandbox.host-podman: 'true'"* ]]
    [[ $config_output == *"label=disable"* ]]
    [[ $config_output == *"seccomp=unconfined"* ]]
done

plain_config=$(
    CONTAINER_NAME=dev-sandbox-check \
    WORKSPACE_DIR=/host/workspace \
    SANDBOX_SSH_PORT=22999 \
    SANDBOX_SSH_AUTHORIZED_KEYS_FILE=/tmp/authorized_keys \
    podman-compose \
        --file compose.yaml \
        --file compose.rocm.yaml \
        --project-name dev-sandbox-check \
        config 2>/dev/null
)
[[ $plain_config != *CONTAINER_HOST* ]]
[[ $plain_config != *host-podman* ]]

workspace="$TEST_ROOT/host-podman-workspace"
container_name=dev-sandbox-host-podman-workspace
mkdir -p -- "$workspace"
touch "$FAKE_PODMAN_DATA/exists.$container_name" "$FAKE_PODMAN_DATA/host-podman.$container_name"
printf '%s\n' true > "$FAKE_PODMAN_DATA/running.$container_name"
printf '%s\n' 22020 > "$FAKE_PODMAN_DATA/port.$container_name"
cat > "$FAKE_PODMAN_DATA/inspect.$container_name" <<'EOF'
STARTED=2026-09-16 12:00:00 +0900 JST
IMAGE=localhost/dev-sandbox-rocm:latest
EOF

(
    cd -- "$workspace"
    PATH="$REPOSITORY_DIR/tests/fake-bin:$ORIGINAL_PATH" \
    XDG_RUNTIME_DIR="$TEST_RUNTIME_DIR" \
    XDG_STATE_HOME="$TEST_STATE_HOME" \
    "$REPOSITORY_DIR/start" >/dev/null
)

echo "host Podman tests passed"
