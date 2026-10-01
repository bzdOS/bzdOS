#!/bin/sh
# vm-setup-sway.sh — Install and configure Sway (i3-like Wayland compositor)
set -eu

. "$(dirname "$0")/_ssh.sh"

echo "=== Sway Compositor Setup ==="
echo ""

echo "[1/4] Installing Sway from pkg..."
ssh_root "pkg install -y sway swaybg swayidle swaylock 2>&1 | tail -10"

echo ""
echo "[2/4] Creating Sway configuration directory..."
ssh_guest "mkdir -p /home/freebsd/.config/sway"

echo ""
echo "[3/4] Installing sway config (fbdev-optimized for Phase 0)..."
ssh_guest "cat > /home/freebsd/.config/sway/config << 'SWAYEOF'
# sway configuration for bsdOS embedded display (Phase 0)

# Use FreeBSD keyboard layout (Alt = Mod1)
set \$mod Mod1

# Use fbdev for testing, DRM when available
output LVDS1 resolution 720x1440 position 0 0

# Workspace names
workspace 1 \"main\"
workspace 2 \"debug\"

# keybindings
bindsym \$mod+Return exec foot
bindsym \$mod+q kill
bindsym \$mod+d exec dmenu_run
bindsym \$mod+1 workspace 1
bindsym \$mod+2 workspace 2
bindsym \$mod+Shift+1 move container to workspace 1
bindsym \$mod+Shift+2 move container to workspace 2
bindsym \$mod+Shift+c reload
bindsym \$mod+Shift+e exit
bindsym \$mod+Left focus left
bindsym \$mod+Right focus right
bindsym \$mod+Up focus up
bindsym \$mod+Down focus down

# floating_modifier allows window movement/resizing with alt+mouse
floating_modifier \$mod normal

# Gaps and borders
gaps inner 0
gaps outer 0
default_border none
default_floating_border pixel 1

# Status bar
bar {
  status_command while true; do echo \"bsdOS $(date '+%H:%M:%S')\"; sleep 1; done
  position bottom
  font pango:monospace 10
  colors {
    background #0d1729
    statusline #ffffff
    separator  #666666
  }
}

# Load input configuration
input * {
  xkb_layout us
  accel_profile adaptive
  pointer_accel 0.0
}
SWAYEOF"

echo ""
echo "[4/4] Verifying Sway installation..."
ssh_root "sway --version 2>&1 | head -1"

echo ""
echo "=== Setup complete ==="
echo "Next: make vm-start-sway"
echo "View log: make vm-sway-log"
