#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="claude-code:kiro-minimal"

RUNTIME="podman"
if [[ "$1" == "--use-docker" ]]; then
    RUNTIME="docker"
fi

echo "Building $IMAGE_NAME with $RUNTIME..."
$RUNTIME build -f "$SCRIPT_DIR/Containerfile" -t "$IMAGE_NAME" "$SCRIPT_DIR"

echo "Build complete: $IMAGE_NAME"
