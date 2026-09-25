#!/usr/bin/env bash

set -euo pipefail

REPOSITORY_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

XDG_STATE_HOME="$TEST_ROOT/state"
SANDBOX_SSH_AUTHORIZED_KEYS_FILE="$TEST_ROOT/authorized_keys"
export XDG_STATE_HOME SANDBOX_SSH_AUTHORIZED_KEYS_FILE

source "$REPOSITORY_DIR/lib/sandbox.sh"
SANDBOX_DIR=$REPOSITORY_DIR

ssh-keygen -q -t ed25519 -N '' -f "$TEST_ROOT/identity"
cp -- "$TEST_ROOT/identity.pub" "$SSH_AUTHORIZED_KEYS_FILE"
chmod 0600 "$SSH_AUTHORIZED_KEYS_FILE"

sandbox_check_ssh_authorized_keys
sandbox_prepare_ssh_authorized_keys_mount

[[ -f $SSH_AUTHORIZED_KEYS_MOUNT_FILE ]]
cmp -- "$SSH_AUTHORIZED_KEYS_FILE" "$SSH_AUTHORIZED_KEYS_MOUNT_FILE"
[[ $(stat -c '%a' "$SSH_AUTHORIZED_KEYS_FILE") == 600 ]]
[[ $(stat -c '%a' "$SSH_AUTHORIZED_KEYS_MOUNT_FILE") == 644 ]]
[[ $(stat -c '%u' "$SSH_AUTHORIZED_KEYS_MOUNT_FILE") == "$(id -u)" ]]
[[ $(stat -c '%a' "$SANDBOX_STATE_DIR") == 700 ]]

old_inode=$(stat -c '%i' "$SSH_AUTHORIZED_KEYS_MOUNT_FILE")
printf '# refreshed\n' >> "$SSH_AUTHORIZED_KEYS_FILE"
sandbox_prepare_ssh_authorized_keys_mount
new_inode=$(stat -c '%i' "$SSH_AUTHORIZED_KEYS_MOUNT_FILE")
[[ $new_inode != "$old_inode" ]]
cmp -- "$SSH_AUTHORIZED_KEYS_FILE" "$SSH_AUTHORIZED_KEYS_MOUNT_FILE"

config_output=$(
    CONTAINER_NAME=dev-sandbox-check \
    WORKSPACE_DIR=/host/workspace \
    SANDBOX_SSH_PORT=22999 \
    SANDBOX_SSH_AUTHORIZED_KEYS_MOUNT_FILE="$SSH_AUTHORIZED_KEYS_MOUNT_FILE" \
    podman-compose \
        --file "$REPOSITORY_DIR/compose.yaml" \
        --file "$REPOSITORY_DIR/compose.rocm.yaml" \
        --project-name dev-sandbox-check \
        config 2>/dev/null
)
[[ $config_output == *"$SSH_AUTHORIZED_KEYS_MOUNT_FILE:/run/dev-sandbox/authorized_keys.source:ro"* ]]
[[ $config_output != *"$SSH_AUTHORIZED_KEYS_FILE:/etc/dev-sandbox/authorized_keys"* ]]

grep -Fq -- 'install -o root -g root -m 0600 -- "$authorized_keys_source" "$authorized_keys"' \
    "$REPOSITORY_DIR/container/start-sshd"

echo "SSH authorized_keys tests passed"
