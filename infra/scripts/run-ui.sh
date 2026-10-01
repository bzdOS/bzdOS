#!/bin/sh
set -eu

BIN="$(dirname "$0")/../../ui-plasma-qml/build/bsdos-ui"
[ -f "$BIN" ] || { echo "No binary — run: make build-ui"; exit 1; }
echo "Starting bsdOS UI (connects to broker on localhost:9999)..."
exec "$BIN"
