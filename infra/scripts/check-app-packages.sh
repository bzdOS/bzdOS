#!/bin/sh
# Check availability of desktop applications in FreeBSD pkg repository
set -eu

. "$(dirname "$0")/_ssh.sh"

echo "=== Available packages for bsdOS apps ==="
echo ""

# List of desktop applications to check
apps="firefox thunderbird telegram-desktop thunar mousepad foot xterm gedit chromium libreoffice vlc gimp"
for app in $apps; do
    # Use pkg search without -x (exact match) first to see if it works
    result=$(ssh_guest "pkg search $app" 2>&1 | grep -E "^${app}-" | head -1 || true)
    if [ -n "$result" ]; then
        # Extract package name and version
        pkg_info=$(echo "$result" | awk '{print $1; exit}')
        echo "✓ $app: $pkg_info"
    else
        echo "✗ $app: not found"
    fi
done

echo ""
echo "=== Checking additional development/system tools ==="

# Also search for common console tools (with alternative names)
tools="tmux vim curl wget git bash zsh gcc llvm python python3 node lua perl ruby"
for tool in $tools; do
    result=$(ssh_guest "pkg search $tool" 2>&1 | grep -E "^${tool}-" | head -1 || true)
    if [ -n "$result" ]; then
        pkg_info=$(echo "$result" | awk '{print $1; exit}')
        echo "✓ $tool: $pkg_info"
    else
        echo "✗ $tool: not found"
    fi
done

echo ""
echo "=== Summary ==="
echo "Run 'pkg search <name>' to search for additional packages"
echo "Run 'pkg install <package>' to install a package"
