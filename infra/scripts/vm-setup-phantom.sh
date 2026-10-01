#!/bin/sh
set -eu
. "$(dirname "$0")/_ssh.sh"

echo "Setting up Phantom Browser (Chromium headless + CDP port 9222)..."

# Установить Chromium (headless доступен через --headless флаг)
echo "Installing Chromium..."
ssh_root "pkg install -y chromium"

# Создать wrapper-скрипт для запуска Chromium в headless режиме с CDP
ssh_root "cat > /usr/local/bin/bsdos-chrome << 'EOF'
#!/bin/sh
# bsdOS Chromium wrapper — headless + CDP remote debugging
exec chrome \
    --headless \
    --disable-gpu \
    --no-sandbox \
    --remote-debugging-port=9222 \
    --remote-debugging-address=0.0.0.0 \
    --user-data-dir=/var/bsdos/chrome-profile \
    --window-size=1280,800 \
    \"\$@\"
EOF
chmod +x /usr/local/bin/bsdos-chrome"

# Создать директорию профиля
ssh_root "mkdir -p /var/bsdos/chrome-profile"

echo "=== Phantom Browser setup complete ==="
echo "  Start: make phantom-start"
echo "  CDP:   http://localhost:9222/json (via hostfwd)"
echo "  Stream: Zenoh bsdos/qemu/browser/display"
