# ── Phantom browser launcher ───────────────────────────────────────────────
# Launches wpewebkit-fdo (WPE WebKit) inside cage on the appBrowser Wayland display.
# bsdos-core picks up the stream via bsdos/app/appBrowser/stream Zenoh topic.
# Per SPEC_2stream_squirrel.md §4 (2 cage instances, 1 app each).

#!/bin/sh
set -e

export XDG_RUNTIME_DIR=/tmp/wayland-run
export WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-1}
export URL="${1:-about:blank}"

exec cog --platform=fdo "$URL"
