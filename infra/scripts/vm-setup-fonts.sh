#!/bin/sh
set -eu
. "$(dirname "$0")/_ssh.sh"
echo "Installing JetBrains Mono font..."
ssh_root "pkg install -y jetbrains-mono 2>/dev/null || fetch -o /tmp/jbmono.zip https://github.com/JetBrains/JetBrainsMono/releases/download/v2.304/JetBrainsMono-2.304.zip 2>/dev/null; true"
ssh_root "mkdir -p /usr/local/share/fonts/JetBrainsMono && fc-cache -f 2>/dev/null || true"
echo "Fonts ready"
