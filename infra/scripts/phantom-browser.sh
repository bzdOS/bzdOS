#!/bin/sh
## MAKE-TARGETS ##
# phantom-setup:  $(SCRIPTS)/phantom-browser.sh setup
# phantom-start:  $(SCRIPTS)/phantom-browser.sh start
# phantom-open:   URL=$(URL) $(SCRIPTS)/phantom-browser.sh open $(URL)
# phantom-stop:   $(SCRIPTS)/phantom-browser.sh stop
# phantom-status: $(SCRIPTS)/phantom-browser.sh status
## END-MAKE-TARGETS ##

set -eu
. "$(dirname "$0")/_agent.sh"

JAIL_NAME="appBrowser"
WAYLAND_DISPLAY="wayland-ghost-0"
WAYLAND_RUNTIME_DIR="/tmp/wayland-run"
CDP_PORT="9222"
CDP_TIMEOUT="30"

# Print usage and exit with error code
usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") <command> [args]

Commands:
  setup              Install Chromium in $JAIL_NAME jail via agent
  start              Start Chromium headless with CDP on port $CDP_PORT
  open URL           Open URL in running Chromium instance (via CDP)
  stop               Stop Chromium process in jail
  status             Show jail status and CDP connectivity

EOF
    exit 1
}

# Setup: install Chromium in the jail
cmd_setup() {
    echo "Setting up Phantom Browser ($JAIL_NAME jail)..."

    if ! agent_check_jail "$JAIL_NAME"; then
        echo "ERROR: jail '$JAIL_NAME' not found"
        echo "Hint: Run 'make jail-setup' first to create jails"
        exit 1
    fi

    echo "Installing Chromium in jail $JAIL_NAME..."
    if agent_exec "pkg -j '$JAIL_NAME' install -y chromium"; then
        echo "Chromium installed successfully"
    else
        echo "WARNING: pkg install returned non-zero (may be cached package already installed)"
    fi
}

# Start: launch Chromium with Wayland in the jail
cmd_start() {
    echo "Starting Chromium in $JAIL_NAME jail with Wayland..."

    if ! agent_check_jail "$JAIL_NAME"; then
        echo "ERROR: jail '$JAIL_NAME' not found"
        exit 1
    fi

    # Kill any existing Chromium instances first
    echo "Cleaning up previous Chromium processes..."
    agent_exec "pkill -9 chromium || true" 5
    sleep 1

    # Start Chromium with Wayland display and CDP
    # Using agent_exec_bg to start in background and return immediately
    echo "Launching Chromium headless..."
    agent_exec_bg "jexec '$JAIL_NAME' env XDG_RUNTIME_DIR='$WAYLAND_RUNTIME_DIR' \
        WAYLAND_DISPLAY='$WAYLAND_DISPLAY' \
        /usr/local/bin/chromium --no-sandbox --headless=new \
        --remote-debugging-port=$CDP_PORT --window-size=1280,720 about:blank"

    # Wait a moment for Chromium to start
    sleep 2

    # Verify CDP is listening
    echo "Verifying CDP availability..."
    local retry_count=0
    local max_retries=15
    while [ $retry_count -lt $max_retries ]; do
        if agent_exec "nc -zv 127.0.0.1 $CDP_PORT 2>/dev/null" 5 >/dev/null 2>&1; then
            echo "✓ CDP listening on port $CDP_PORT"
            echo "  CDP API: http://localhost:$CDP_PORT/json"
            echo "  Wayland: $WAYLAND_DISPLAY → bsdos/global/wayland/stream"
            return 0
        fi
        retry_count=$((retry_count + 1))
        echo "  Waiting for CDP... ($retry_count/$max_retries)"
        sleep 1
    done

    echo "WARNING: CDP did not become available after ${CDP_TIMEOUT}s"
    echo "Check: agent_exec 'ps -J $JAIL_NAME | grep chromium'"
    return 1
}

# Open: navigate to URL in running Chromium via CDP
cmd_open() {
    local url="${1:?usage: $(basename "$0") open <URL>}"

    echo "Opening URL in Chromium: $url"

    # Check that CDP is responding
    if ! agent_exec "nc -zv 127.0.0.1 $CDP_PORT 2>/dev/null" 5 >/dev/null 2>&1; then
        echo "ERROR: CDP not listening on port $CDP_PORT"
        echo "Hint: Run '$(basename "$0") start' first"
        exit 1
    fi

    # Use CDP JSON API to create new tab/window with URL
    # endpoint: /json/new?url=<URL>
    echo "Sending CDP command: /json/new?url=$url"
    if agent_exec "fetch -qo- 'http://127.0.0.1:$CDP_PORT/json/new?url=$url' 2>/dev/null | head -10" 10; then
        echo "✓ URL opened in Chromium"
    else
        echo "WARNING: CDP command may have failed, but Chromium may still have navigated"
    fi
}

# Stop: kill Chromium in the jail
cmd_stop() {
    echo "Stopping Chromium in $JAIL_NAME jail..."

    if ! agent_check_jail "$JAIL_NAME"; then
        echo "ERROR: jail '$JAIL_NAME' not found"
        exit 1
    fi

    # Graceful kill first, then force
    agent_exec "pkill chromium || true" 5
    sleep 1
    agent_exec "pkill -9 chromium || true" 5

    echo "Chromium stopped"
}

# Status: show jail and CDP status
cmd_status() {
    echo "Status for Phantom Browser ($JAIL_NAME):"
    echo ""

    if ! agent_check_jail "$JAIL_NAME"; then
        echo "  Jail: NOT FOUND"
        exit 1
    fi

    echo "  Jail: exists"

    # Check if Chromium process is running
    local chrome_count
    chrome_count=$(agent_exec "pgrep -cj '$JAIL_NAME' chromium 2>/dev/null || echo 0" 10)
    chrome_count=$(printf '%s\n' "$chrome_count" | tail -1 | tr -d ' ')

    if [ "$chrome_count" -gt 0 ]; then
        echo "  Process: running ($chrome_count instances)"
    else
        echo "  Process: not running"
    fi

    # Check CDP port availability
    if agent_exec "nc -zv 127.0.0.1 $CDP_PORT 2>/dev/null" 5 >/dev/null 2>&1; then
        echo "  CDP: listening on port $CDP_PORT ✓"
        echo "  API: http://localhost:$CDP_PORT/json"
    else
        echo "  CDP: not listening on port $CDP_PORT"
    fi

    # Check Wayland runtime directory
    if agent_exec "[ -d '$WAYLAND_RUNTIME_DIR' ]" 5; then
        echo "  Wayland: $WAYLAND_RUNTIME_DIR exists"
    else
        echo "  Wayland: $WAYLAND_RUNTIME_DIR NOT FOUND"
    fi
}

# Main dispatcher
case "${1:-}" in
    setup)   cmd_setup ;;
    start)   cmd_start ;;
    open)    cmd_open "$2" ;;
    stop)    cmd_stop ;;
    status)  cmd_status ;;
    *)       usage ;;
esac
