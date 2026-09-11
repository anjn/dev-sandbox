#!/usr/bin/env bash

set -euo pipefail

REPOSITORY_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

FAKE_PODMAN_DATA="$TEST_ROOT/podman"
TEST_STATE_HOME="$TEST_ROOT/state"
WORKSPACE_DIR="$TEST_ROOT/alpha"
CONTAINER_NAME=dev-sandbox-alpha
export FAKE_PODMAN_DATA
mkdir -p -- "$FAKE_PODMAN_DATA" "$TEST_STATE_HOME/dev-sandbox" "$WORKSPACE_DIR"

touch "$FAKE_PODMAN_DATA/exists.$CONTAINER_NAME"
printf '%s\n' false > "$FAKE_PODMAN_DATA/running.$CONTAINER_NAME"
printf '%s\n' 22010 > "$FAKE_PODMAN_DATA/port.$CONTAINER_NAME"
cat > "$FAKE_PODMAN_DATA/inspect.$CONTAINER_NAME" <<'EOF'
STARTED=2026-09-02 09:30:00 +0900 JST
IMAGE=localhost/dev-sandbox-rocm:latest
EOF
cat > "$TEST_STATE_HOME/dev-sandbox/$CONTAINER_NAME.metadata" <<EOF
version=1
workspace=$WORKSPACE_DIR
role=base
platform=rocm
image=localhost/dev-sandbox-rocm:latest
last_started=2026-09-01 10:00:00 +0900 JST
EOF

start_output=$(
    cd -- "$WORKSPACE_DIR"
    PATH="$REPOSITORY_DIR/tests/fake-bin:$PATH" \
    XDG_STATE_HOME="$TEST_STATE_HOME" \
    SANDBOX_SSH_PORT=22999 \
    "$REPOSITORY_DIR/start"
)
[[ $start_output == *"$CONTAINER_NAME"* ]]
[[ $start_output == *"-p 22010"* ]]
[[ $(< "$FAKE_PODMAN_DATA/running.$CONTAINER_NAME") == true ]]
[[ $(< "$TEST_STATE_HOME/dev-sandbox/$CONTAINER_NAME.metadata") == *"last_started=2026-09-02 09:30:00 +0900 JST"* ]]

second_output=$(
    cd -- "$WORKSPACE_DIR"
    PATH="$REPOSITORY_DIR/tests/fake-bin:$PATH" \
    XDG_STATE_HOME="$TEST_STATE_HOME" \
    "$REPOSITORY_DIR/start"
)
[[ $second_output == *"$CONTAINER_NAME is already running."* ]]
[[ $(wc -l < "$FAKE_PODMAN_DATA/start.log") == 1 ]]

missing_workspace="$TEST_ROOT/missing"
mkdir -p -- "$missing_workspace"
if missing_output=$(
    cd -- "$missing_workspace"
    PATH="$REPOSITORY_DIR/tests/fake-bin:$PATH" \
    XDG_STATE_HOME="$TEST_STATE_HOME" \
    "$REPOSITORY_DIR/start" 2>&1
); then
    echo "start should fail when the workspace container does not exist" >&2
    exit 1
fi
[[ $missing_output == *"Run $REPOSITORY_DIR/up to create it."* ]]

echo "start tests passed"
