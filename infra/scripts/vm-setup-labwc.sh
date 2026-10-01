#!/bin/sh
# vm-setup-labwc.sh — Install and configure labwc (minimal stacking Wayland compositor)
set -eu

. "$(dirname "$0")/_ssh.sh"

echo "=== labwc Compositor Setup ==="
echo ""

echo "[1/3] Installing labwc from pkg..."
ssh_root "pkg install -y labwc 2>&1 | tail -10"

echo ""
echo "[2/3] Creating labwc configuration directory..."
ssh_guest "mkdir -p /home/freebsd/.config/labwc"

echo ""
echo "[3/3] Installing labwc.conf (minimal config, fbdev backend Phase 0)..."
ssh_guest "cat > /home/freebsd/.config/labwc/rc.xml << 'RCEOF'
<?xml version=\"1.0\"?>
<labwc>
  <core>
    <decor>none</decor>
    <gap>0</gap>
    <adaptiveSync>no</adaptiveSync>
  </core>

  <theme>
    <name>default</name>
    <cornerRadius>0</cornerRadius>
  </theme>

  <keyboard>
    <default />
    <keybind key=\"Alt+Escape\">
      <action name=\"Close\" />
    </keybind>
    <keybind key=\"Super_L\">
      <action name=\"ShowMenu\" type=\"root\" />
    </keybind>
  </keyboard>

  <mouse>
    <doubleClickTime>500</doubleClickTime>
    <scrollFactor>1.0</scrollFactor>
  </mouse>

  <libinput>
    <accelProfile>adaptive</accelProfile>
    <naturalScroll>no</naturalScroll>
  </libinput>
</labwc>
RCEOF"

echo ""
echo "[4/3] Verifying labwc installation..."
ssh_root "labwc --help 2>&1 | head -3"

echo ""
echo "=== Setup complete ==="
echo "Next: make vm-start-labwc"
echo "View log: make vm-labwc-log"
