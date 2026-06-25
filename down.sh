#!/usr/bin/env bash

# dev-sandbox directory
sandbox_dir=$(dirname $(readlink -f $0))

# target 
target_dir=$(readlink -f $(pwd))
target_name=$(basename $target_dir)

# name
name="dev-sandbox-$target_name"

cd $sandbox_dir

CONTAINER_NAME="$name" \
WORKSPACE_DIR="$target_dir" \
podman-compose \
    --project-name $name \
    down

podman ps -a

