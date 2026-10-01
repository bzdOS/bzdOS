#!/bin/sh
# Deploy rc.d autostart services for bsdOS components.
# Usage: vm-setup-autostart.sh [deploy|enable|enable-all|disable|status]
set -eu
. "$(dirname "$0")/_ssh.sh"

MODE="${1:-deploy}"
RCD_DIR="$(dirname "$0")/../rc.d"

# Individual services (legacy + browser pipeline)
SERVICES="bsdos_agent bsdos_cage bsdos_cage_browser bsdos_tunnel bsdos_tunnel_browser bsdos_core bsdos_firefox bsdos_pipeline"

SCRIPTS_DIR="$(dirname "$0")"

echo "=== bsdOS rc.d Services ==="

# Install supervisor binary
if [ -f "$SCRIPTS_DIR/bsdos-pipeline" ]; then
    ssh_root "cat > /usr/local/bin/bsdos-pipeline" < "$SCRIPTS_DIR/bsdos-pipeline"
    ssh_root "chmod +x /usr/local/bin/bsdos-pipeline"
    echo "  installed: /usr/local/bin/bsdos-pipeline"
fi

for svc in $SERVICES; do
    if [ -f "$RCD_DIR/$svc" ]; then
        ssh_root "cat > /usr/local/etc/rc.d/$svc" < "$RCD_DIR/$svc"
        ssh_root "chmod +x /usr/local/etc/rc.d/$svc"
        echo "  installed: $svc"
    else
        echo "  SKIP: $RCD_DIR/$svc not found"
    fi
done

case "$MODE" in
enable)
    # Enable unified pipeline (replaces individual cage/tunnel/core)
    ssh_root "sysrc bsdos_agent_enable=YES bsdos_pipeline_enable=YES \
        bsdos_cage_enable=NO bsdos_tunnel_enable=NO bsdos_core_enable=NO"
    echo "Agent + pipeline supervisor enabled at boot."
    ;;
enable-all)
    ssh_root "sysrc bsdos_agent_enable=YES \
        bsdos_pipeline_enable=YES \
        bsdos_cage_enable=NO bsdos_tunnel_enable=NO bsdos_core_enable=NO \
        bsdos_cage_browser_enable=YES bsdos_tunnel_browser_enable=YES \
        bsdos_firefox_enable=YES"
    echo "All services enabled at boot."
    ;;
disable)
    ssh_root "sysrc bsdos_agent_enable=NO \
        bsdos_pipeline_enable=NO \
        bsdos_cage_enable=NO bsdos_cage_browser_enable=NO \
        bsdos_tunnel_enable=NO bsdos_tunnel_browser_enable=NO \
        bsdos_core_enable=NO \
        bsdos_firefox_enable=NO 2>/dev/null || true"
    echo "All services disabled."
    ;;
esac

echo ""
echo "rc.conf:"
ssh_root "grep bsdos_ /etc/rc.conf 2>/dev/null || echo '  (nothing yet)'"
