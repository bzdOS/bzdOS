#!/bin/sh
set -eu
. "$(dirname "$0")/_ssh.sh"
PROJECT="$(dirname "$0")/../.."

echo "Syncing lifecycled sources to guest..."
ssh_root "mkdir -p /opt/lifecycled/src && chown -R freebsd /opt/lifecycled"
scp -P "$VM_SSH_PORT" -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -r "$PROJECT/lifecycled/src" "$PROJECT/lifecycled/Cargo.toml" \
    freebsd@localhost:/opt/lifecycled/

echo "Building bsdos-lifecycled in guest..."
ssh_guest "cd /opt/lifecycled && cargo build --release"
# Остановить демон перед cp (избегаем "Text file busy" под TCG)
ssh_root "pkill -KILL -f bsdos-lifecycled 2>/dev/null; sleep 2; true"
# install(1) атомарно заменяет бинарь даже при занятом файле
ssh_root "install -m 755 /opt/lifecycled/target/release/bsdos-lifecycled /usr/local/bin/bsdos-lifecycled"
echo "Built: /usr/local/bin/bsdos-lifecycled"
