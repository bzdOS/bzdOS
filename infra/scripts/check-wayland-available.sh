#!/bin/sh
# check-wayland-available.sh — Query available Wayland compositors in FreeBSD pkg
set -eu

. "$(dirname "$0")/_ssh.sh"

echo "=== Wayland Compositors Available in FreeBSD 15.1 pkg ==="
echo ""

echo "[1] Weston (reference implementation, fbdev + DRM backends)"
ssh_guest "pkg search weston 2>&1 | grep -E '^weston' | head -3" || echo "  (not found)"

echo ""
echo "[2] Sway (i3-like tiling, Wayland native)"
ssh_guest "pkg search sway 2>&1 | grep -E '^sway' | head -3" || echo "  (not found)"

echo ""
echo "[3] Cage (kiosk, single-app launcher)"
ssh_guest "pkg search cage 2>&1 | grep -E '^cage' | head -3" || echo "  (not found)"

echo ""
echo "[4] labwc (minimal tiling, GTK/libadwaita native)"
ssh_guest "pkg search labwc 2>&1 | grep -E '^labwc' | head -3" || echo "  (not found)"

echo ""
echo "[5] Wayfire (3D effects, plugin-based)"
ssh_guest "pkg search wayfire 2>&1 | grep -E '^wayfire' | head -3" || echo "  (not found)"

echo ""
echo "[6] Gnome Shell (Wayland, requires systemd — likely unavailable on FreeBSD)"
ssh_guest "pkg search gnome-shell 2>&1 | grep -E '^gnome-shell' | head -3" || echo "  (not found)"

echo ""
echo "[7] KDE/Plasma (Wayland, KWin)"
ssh_guest "pkg search kde-plasma-desktop 2>&1 | grep -E '^kde' | head -3" || echo "  (not found)"

echo ""
echo "[8] Kiwmi (minimal, keyboard-driven)"
ssh_guest "pkg search kiwmi 2>&1 | grep -E '^kiwmi' | head -3" || echo "  (not found)"

echo ""
echo "[9] Hikari (tiling, wayland-native)"
ssh_guest "pkg search hikari 2>&1 | grep -E '^hikari' | head -3" || echo "  (not found)"

echo ""
echo "=== Screen Capture & Recording Tools ==="
echo ""

echo "[A] Grim (screenshot utility for Wayland)"
ssh_guest "pkg search grim 2>&1 | grep -E '^grim' | head -3" || echo "  (not found)"

echo ""
echo "[B] wf-recorder (screen recording for Wayland)"
ssh_guest "pkg search wf-recorder 2>&1 | grep -E '^wf-recorder' | head -3" || echo "  (not found)"

echo ""
echo "[C] Slurp (region selection for Wayland)"
ssh_guest "pkg search slurp 2>&1 | grep -E '^slurp' | head -3" || echo "  (not found)"

echo ""
echo "[D] XWayland (X11 compatibility layer on Wayland)"
ssh_guest "pkg search xwayland 2>&1 | grep -E '^xwayland' | head -3" || echo "  (not found)"

echo ""
echo "=== Core Wayland Libraries ==="
ssh_guest "pkg list | grep -i 'wayland\|wlroots\|libxkb' || echo '  (none installed yet)'"
