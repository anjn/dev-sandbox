#!/usr/bin/env bash

set -euo pipefail

REPOSITORY_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

source "$REPOSITORY_DIR/lib/sandbox.sh"
SANDBOX_DIR=$TEST_ROOT
mkdir -p -- "$SANDBOX_DIR/lib"
touch "$TEST_ROOT/rw-device" "$TEST_ROOT/read-device"
cat > "$SANDBOX_DIR/lib/jetson-gpu-devices.sh" <<EOF
RW_DEVICES=("$TEST_ROOT/rw-device")
READ_DEVICES=("$TEST_ROOT/read-device")
EOF

getfacl() {
    local device=${*: -1}
    cat -- "$device.acl"
}

user_name=$(id -un)
printf 'user:%s:rw-\nmask::rw-\n' "$user_name" > "$TEST_ROOT/rw-device.acl"
printf 'user:%s:r--\nmask::r--\n' "$user_name" > "$TEST_ROOT/read-device.acl"
sandbox_check_jetson_gpu_acl

printf 'user:%s:rw-\nmask::r--\n' "$user_name" > "$TEST_ROOT/rw-device.acl"
if sandbox_check_jetson_gpu_acl 2> "$TEST_ROOT/error"; then
    echo "A masked write permission should fail" >&2
    exit 1
fi
grep -Fq -- "$TEST_ROOT/rw-device" "$TEST_ROOT/error"
grep -Fq -- "sudo $TEST_ROOT/setup-jetson-gpu-access" "$TEST_ROOT/error"
if grep -Fq -- '  cd ' "$TEST_ROOT/error"; then
    echo "The setup instruction should be a single command" >&2
    exit 1
fi

printf 'user:someone-else:rw-\nmask::rw-\n' > "$TEST_ROOT/rw-device.acl"
if sandbox_check_jetson_gpu_acl >/dev/null 2>&1; then
    echo "Another user's ACL should fail" >&2
    exit 1
fi

printf 'user:%s:rw-\nmask::rw-\n' "$user_name" > "$TEST_ROOT/rw-device.acl"
rm -- "$TEST_ROOT/read-device.acl"
if sandbox_check_jetson_gpu_acl >/dev/null 2>&1; then
    echo "An unreadable ACL should fail" >&2
    exit 1
fi

echo "Jetson GPU ACL tests passed"
