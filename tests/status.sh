#!/usr/bin/env bash

set -euo pipefail

REPOSITORY_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
cd -- "$REPOSITORY_DIR"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

FAKE_PODMAN_DATA="$TEST_ROOT/podman"
TEST_STATE_HOME="$TEST_ROOT/state"
export FAKE_PODMAN_DATA
mkdir -p -- "$FAKE_PODMAN_DATA" "$TEST_STATE_HOME/dev-sandbox"

assert_contains() {
    local output=$1
    local expected=$2

    if [[ $output != *"$expected"* ]]; then
        echo "Expected output to contain: $expected" >&2
        echo "$output" >&2
        return 1
    fi
}

cat > "$FAKE_PODMAN_DATA/containers" <<'EOF'
dev-sandbox-zeta
dev-sandbox-not-ours
dev-sandbox-alpha
EOF

cat > "$FAKE_PODMAN_DATA/inspect.dev-sandbox-alpha" <<'EOF'
STATUS=running
STARTED=2026-09-01 10:26:41.39891501 +0900 JST
IMAGE=localhost/dev-sandbox-rocm:latest
MANAGED=true
WORKSPACE_LABEL=/work/alpha project
ROLE=base
PLATFORM=rocm
COMPOSE_SERVICE=dev
COMPOSE_PROJECT=dev-sandbox-alpha
ENV=SANDBOX_SSH_PORT=22001
WORKSPACE_MOUNT=/wrong/workspace
EOF

cat > "$FAKE_PODMAN_DATA/inspect.dev-sandbox-zeta" <<'EOF'
STATUS=exited
STARTED=2026-08-30 08:00:00 +0900 JST
IMAGE=localhost/dev-sandbox-ros2-tools-amd:latest
MANAGED=
WORKSPACE_LABEL=
ROLE=
PLATFORM=
COMPOSE_SERVICE=dev
COMPOSE_PROJECT=dev-sandbox-zeta
ENV=SANDBOX_SSH_PORT=22002
WORKSPACE_MOUNT=/work/zeta
EOF

cat > "$FAKE_PODMAN_DATA/inspect.dev-sandbox-not-ours" <<'EOF'
STATUS=running
STARTED=2026-09-01 11:00:00 +0900 JST
IMAGE=localhost/unrelated:latest
MANAGED=
WORKSPACE_LABEL=
ROLE=
PLATFORM=
COMPOSE_SERVICE=other
COMPOSE_PROJECT=other
ENV=SANDBOX_SSH_PORT=22999
WORKSPACE_MOUNT=/work/unrelated
EOF

cat > "$FAKE_PODMAN_DATA/inspect.dev-sandbox-metadata" <<'EOF'
STATUS=running
STARTED=2026-09-01 13:00:00 +0900 JST
IMAGE=localhost/dev-sandbox-rocm:latest
EOF

printf '%s\n' 22901 > "$TEST_STATE_HOME/dev-sandbox/dev-sandbox-alpha.ssh-port"
printf '%s\n' 22003 > "$TEST_STATE_HOME/dev-sandbox/dev-sandbox-beta.ssh-port"
printf '%s\n' 22004 > "$TEST_STATE_HOME/dev-sandbox/dev-sandbox-old.ssh-port"
cat > "$TEST_STATE_HOME/dev-sandbox/dev-sandbox-beta.metadata" <<'EOF'
version=1
workspace=/work/beta=archive
role=ros2-rocm
platform=rocm
image=localhost/dev-sandbox-ros2-rocm-amd:latest
last_started=2026-08-31 12:00:00 +0900 JST
EOF

status_output=$(
    PATH="$REPOSITORY_DIR/tests/fake-bin:$PATH" \
    XDG_STATE_HOME="$TEST_STATE_HOME" \
    "$REPOSITORY_DIR/status"
)
compact_output=$(printf '%s\n' "$status_output" | awk '{$1=$1; print}')

assert_contains "$status_output" "NAME"
assert_contains "$status_output" "SSH_PORT"
if [[ $status_output == *IMAGE* || $status_output == *localhost/dev-sandbox* ]]; then
    echo "Image column should not be included in status output" >&2
    exit 1
fi
assert_contains "$compact_output" "dev-sandbox-alpha running 22001 base rocm"
assert_contains "$status_output" "/work/alpha project"
assert_contains "$compact_output" "dev-sandbox-beta reserved 22003 ros2-rocm rocm"
assert_contains "$status_output" "2026-08-31T12:00:00+09:00"
assert_contains "$status_output" "/work/beta=archive"
assert_contains "$compact_output" "dev-sandbox-old reserved 22004"
assert_contains "$compact_output" "dev-sandbox-zeta exited 22002 ros2-tools rocm"
if [[ $status_output == *dev-sandbox-not-ours* ]]; then
    echo "Unmanaged container was included in status output" >&2
    exit 1
fi

escape=$'\033'
if [[ $status_output == *"$escape"* ]]; then
    echo "Redirected status output should not contain terminal colors" >&2
    exit 1
fi

color_output=$(
    PATH="$REPOSITORY_DIR/tests/fake-bin:$PATH" \
    XDG_STATE_HOME="$TEST_STATE_HOME" \
    FORCE_COLOR=1 \
    NO_COLOR= \
    "$REPOSITORY_DIR/status"
)
assert_contains "$color_output" "$escape[1mNAME"
assert_contains "$color_output" "$escape[32mrunning"
assert_contains "$color_output" "$escape[36mreserved"
assert_contains "$color_output" "$escape[31mexited"
assert_contains "$color_output" "$escape[35mrocm"

no_color_output=$(
    PATH="$REPOSITORY_DIR/tests/fake-bin:$PATH" \
    XDG_STATE_HOME="$TEST_STATE_HOME" \
    FORCE_COLOR=1 \
    NO_COLOR=1 \
    "$REPOSITORY_DIR/status"
)
if [[ $no_color_output == *"$escape"* ]]; then
    echo "NO_COLOR should disable terminal colors" >&2
    exit 1
fi

mapfile -t output_names < <(printf '%s\n' "$status_output" | awk 'NR > 1 {print $1}')
expected_names=(dev-sandbox-alpha dev-sandbox-beta dev-sandbox-old dev-sandbox-zeta)
if [[ ${output_names[*]} != "${expected_names[*]}" ]]; then
    echo "Status rows are not sorted by name" >&2
    printf 'Actual: %s\n' "${output_names[*]}" >&2
    exit 1
fi

empty_data="$TEST_ROOT/empty-podman"
empty_state="$TEST_ROOT/empty-state"
mkdir -p -- "$empty_data" "$empty_state"
empty_output=$(
    PATH="$REPOSITORY_DIR/tests/fake-bin:$PATH" \
    FAKE_PODMAN_DATA="$empty_data" \
    XDG_STATE_HOME="$empty_state" \
    "$REPOSITORY_DIR/status"
)
[[ $empty_output == "No dev sandboxes found." ]]

help_output=$("$REPOSITORY_DIR/status" --help)
assert_contains "$help_output" "Usage: $REPOSITORY_DIR/status"

if "$REPOSITORY_DIR/status" unexpected > /dev/null 2>&1; then
    echo "Unexpected argument should fail" >&2
    exit 1
else
    argument_status=$?
fi
[[ $argument_status == 2 ]]

if PATH="$REPOSITORY_DIR/tests/fake-bin:$PATH" \
    FAKE_PODMAN_DATA="$empty_data" \
    FAKE_PODMAN_PS_FAIL=1 \
    XDG_STATE_HOME="$empty_state" \
    "$REPOSITORY_DIR/status" > /dev/null 2>&1; then
    echo "Podman failure should fail status" >&2
    exit 1
fi

metadata_workspace="$TEST_ROOT/metadata"
mkdir -p -- "$metadata_workspace"
(
    PATH="$REPOSITORY_DIR/tests/fake-bin:$PATH"
    XDG_STATE_HOME="$TEST_STATE_HOME"
    export PATH XDG_STATE_HOME
    source "$REPOSITORY_DIR/lib/sandbox.sh"
    WORKSPACE_DIR=$metadata_workspace
    CONTAINER_NAME=dev-sandbox-metadata
    SANDBOX_METADATA_STATE_FILE="$TEST_STATE_HOME/dev-sandbox/dev-sandbox-metadata.metadata"
    sandbox_write_metadata base rocm
)
metadata_state_file="$TEST_STATE_HOME/dev-sandbox/dev-sandbox-metadata.metadata"
assert_contains "$(< "$metadata_state_file")" "workspace=$metadata_workspace"
assert_contains "$(< "$metadata_state_file")" "role=base"
assert_contains "$(< "$metadata_state_file")" "platform=rocm"
assert_contains "$(< "$metadata_state_file")" "image=localhost/dev-sandbox-rocm:latest"
assert_contains "$(< "$metadata_state_file")" "last_started=2026-09-01 13:00:00 +0900 JST"
[[ $(stat -c '%a' "$metadata_state_file") == 600 ]]

echo "status tests passed"
