#!/bin/sh
# Run telemetry-client on Linux host.
# Connects to VM through QEMU hostfwd (localhost:7447 — Zenoh port).
#
# Usage:
#   make run-telemetry-client              # use default peer
#   make run-telemetry-client PEER=tcp/localhost:7447

set -eu

PEER="${PEER:-tcp/localhost:7447}"
BINARY="${TELEMETRY_CLIENT_BIN:?telemetry-client lives in the attic now}"

if [ ! -f "$BINARY" ]; then
    echo "Binary not found: $BINARY"
    echo "Run: make build-telemetry-client" >&2
    exit 1
fi

if [ -n "$PEER" ]; then
    "$BINARY" --peer "$PEER"
else
    "$BINARY"
fi
