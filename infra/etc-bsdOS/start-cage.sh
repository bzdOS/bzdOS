#!/bin/sh
# start-cage.sh — launch a cage instance for a single app in its jail.
# Per SPEC_2stream_squirrel.md §4.1 (internal task).
#
# Usage:  start-cage.sh <app_id> <wayland_display> <app_cmd>
#   app_id          = appTerminal | appBrowser
#   wayland_display = wayland-0 | wayland-1
#   app_cmd         = foot | cog --platform=fdo about:blank
#
# This script runs inside each jail's exec.start. Each cage gets its own
# Wayland display + XDG_RUNTIME_DIR. bsdos-core picks up the "READY" signal
# and starts the Zenoh publisher on bsdos/app/<app_id>/stream.
set -eu

APP_ID="${1:?Usage: start-cage.sh <app_id> <wayland_display> <app_cmd>}"
WAYLAND_DISPLAY_NAME="${2:?wayland_display required}"
shift 2
APP_CMD="$*"
if [ -z "$APP_CMD" ]; then
    APP_CMD="foot"
fi

# ── Runtime dir ────────────────────────────────────────────────────────────
export XDG_RUNTIME_DIR="/tmp/wayland-run-${APP_ID}"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

# ── Launch cage as Wayland kiosk compositor ────────────────────────────────
# cage -d = don't run a compositor-selected client, use -- for our app
# --immediate = start cage before app is ready (avoids startup race, per §10.2)
WAYLAND_DISPLAY="$WAYLAND_DISPLAY_NAME" \
    cage -d -- "$APP_CMD" &
CAGE_PID=$!

# Wait for the Wayland socket to appear
for i in 1 2 3 4 5 6 7 8 9 10; do
    if [ -S "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY_NAME}" ]; then
        break
    fi
    sleep 0.3
done

# ── Notify bsdos-core that the cage is ready for streaming ─────────────────
echo "READY ${APP_ID} ${WAYLAND_DISPLAY_NAME} ${CAGE_PID}" | \
    nc -U /var/run/bsdOS/control.sock 2>/dev/null || true

# Wait for cage to exit (keeps jail alive)
wait "$CAGE_PID" 2>/dev/null || true
