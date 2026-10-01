#!/bin/sh
set -eu

. "$(dirname "$0")/_ssh.sh"

echo "=== Setting up custom devfs rules in guest ==="

# Update jail.conf with devfs_ruleset values
echo "Uploading updated jail.conf (with devfs_ruleset 10/11)..."
scp -P "$VM_SSH_PORT" -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "$(dirname "$0")/../../proto/jail.conf" freebsd@localhost:/tmp/jail.conf.new
ssh_guest "su -m root -c 'mv /tmp/jail.conf.new /opt/proto/jail.conf'"

# Install custom devfs rules in guest
echo "Installing custom devfs rules (idempotent — removes old bsdos rules first)..."
# Remove any previous bsdos rules, then append fresh ones
ssh_root 'grep -v bsdos_jail /etc/devfs.rules > /tmp/devfs.rules.new 2>/dev/null || true; mv /tmp/devfs.rules.new /etc/devfs.rules 2>/dev/null || true; printf "\n[bsdos_jail_privileged=10]\nadd include \$devfsrules_jail\nadd path bpf unhide\n\n[bsdos_jail_restricted=11]\nadd include \$devfsrules_jail\n\n" >> /etc/devfs.rules'

# Reload rules from /etc/devfs.rules and explicitly load rulesets into kernel
echo "Loading devfs rulesets into kernel..."
ssh_root 'service devfs restart 2>/dev/null || true
# Explicitly load ruleset 10 (privileged: jail base + bpf)
devfs rule -s 10 delall 2>/dev/null || true
devfs rule -s 10 add include 4
devfs rule -s 10 add path bpf unhide
# Explicitly load ruleset 11 (restricted: jail base + explicitly hide bpf)
devfs rule -s 11 delall 2>/dev/null || true
devfs rule -s 11 add include 4
devfs rule -s 11 add path bpf hide
echo "Ruleset 10 (privileged):" && devfs rule -s 10 show
echo "Ruleset 11 (restricted):" && devfs rule -s 11 show'

echo ""
echo "=== devfs setup complete ==="
echo "  Ruleset 10 (appA): includes bpf (privileged)"
echo "  Ruleset 11 (appB): excludes bpf (restricted)"
