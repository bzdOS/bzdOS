#!/bin/sh
set -eu

. "$(dirname "$0")/_ssh.sh"

echo "Building broker..."
ssh_guest "cd /opt/proto-src/broker && cargo build --release"

echo "Building app..."
ssh_guest "cd /opt/proto-src/app && cargo build --release"

echo "Installing app binary..."
ssh_guest "cp /opt/proto-src/app/target/release/proto-app /opt/proto/app/proto-app"

echo "Build complete"
