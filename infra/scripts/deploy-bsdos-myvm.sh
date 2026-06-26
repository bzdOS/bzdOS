#!/bin/sh
# Deploy bsdOS backend services to myvm.
#
# Model: ssh ONLY from host (this script runs on the host, not inside a make recipe).
# Build on dev VM (rust + warm cargo cache, proven) directly from /mnt/bsdos
# (canonical, target on local UFS), STAGE release binaries to a host dir under
# the repo that BOTH VMs see via 9p, then install on myvm. No cross-VM ssh / scp /
# source-over-ssh. Idempotent. ssh from host only.
#
# Usage:  infra/scripts/deploy-bsdos-myvm.sh [--streams] [--all]
#   --streams   also set up 3-stream env (foot+chrome+cowork) + restart bsdos-core
#   --all       full redeploy: binaries + rc.d + streams
#
# Vars: DEV_IP=<dev-vm-ip>  MYVM_IP=<myvm-ip>  SSH_KEY=<path-to-key>
#
# Make target (add to Makefile manually):
#   deploy-myvm: ; infra/scripts/deploy-bsdos-myvm.sh --all
#   deploy-myvm-streams: ; infra/scripts/deploy-bsdos-myvm.sh --streams
#
# Backend binaries deployed to myvm (built on dev, staged via 9p, installed → /usr/local/bin):
#   bsdos-core         — Zenoh control-plane + StreamManager  (daemon, rc.d/bsdos_core_server)
#   bsdos-lifecycled   — jail lifecycle daemon SIGSTOP/SIGCONT (daemon, rc.d/bsdos_lifecycled)
#   bsdos-pkgd         — .jpk package manager build/inspect/verify/install (CLI, on-demand, no rc.d)
#   broker, jpk-manager, bsdos-telemetry-client — support tools (no rc.d)
set -eu

SSH_KEY="${SSH_KEY:?set SSH_KEY to path of your SSH private key}"
DEV_IP="${DEV_IP:?set DEV_IP to your dev VM IP}"
MYVM_IP="${MYVM_IP:?set MYVM_IP to your production VM IP}"
SSH="ssh -i $SSH_KEY -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
DEV="freebsd@$DEV_IP"
MYVM="freebsd@$MYVM_IP"
STAGE="/mnt/bsdos/artefacts/myvm-bin"   # host /srv/bsdos/artefacts/myvm-bin, seen by both VMs (9p)

OPT_STREAMS=0; OPT_ALL=0
for arg in "$@"; do
  case "$arg" in --streams) OPT_STREAMS=1 ;; --all) OPT_ALL=1; OPT_STREAMS=1 ;; esac
done

# cargo PACKAGE names (== installed bin names here). core needs the zenoh control-plane.
CORE="bsdos-core"
# KNOWN-FAILING on FreeBSD (real compile errors): zfs-snapd (5), push-daemon (3) — kept in
# the list so re-runs surface them; the loop skips a failed build instead of aborting.
REST="broker bsdos-lifecycled bsdos-telemetry-client zfs-snapd bsdos-pkgd jpk-manager push-daemon"
# matrix-voice intentionally EXCLUDED: voice feature, useless on a headless server.

if [ "$OPT_ALL" -eq 1 ]; then
echo "==> [1/5] build backend on dev ($DEV_IP) from /mnt/bsdos (release, local target)"
$SSH "$DEV" "su -m root -c 'sh -s'" <<EOF
set -e
cd /mnt/bsdos
mkdir -p "$STAGE"
echo "-- $CORE --"
env CARGO_TARGET_DIR=/tmp/myvm-rel cargo build --release -p $CORE --locked 2>&1 | tail -2
cp -f /tmp/myvm-rel/release/$CORE "$STAGE/" && echo "staged: $CORE"
for p in $REST; do
  echo "-- \$p --"
  if env CARGO_TARGET_DIR=/tmp/myvm-rel cargo build --release -p "\$p" --locked >/tmp/bld.\$p.log 2>&1; then
    [ -f /tmp/myvm-rel/release/\$p ] && cp -f /tmp/myvm-rel/release/\$p "$STAGE/" && echo "staged: \$p" || echo "MISSING bin: \$p"
  else
    echo "BUILD FAILED: \$p (see /tmp/bld.\$p.log on dev) — skipped"
  fi
done
# Stage wayland-tunnel + wl-keepalive (already built on dev VM)
for wt in wayland-tunnel wl-keepalive; do
  [ -f /usr/local/bin/\$wt ] && cp -f /usr/local/bin/\$wt "$STAGE/" && echo "staged: \$wt" || echo "MISSING: \$wt"
done
echo "-- staged --"; ls -1 "$STAGE"
EOF

echo "==> [2/5] install binaries on myvm ($MYVM_IP)"
$SSH "$MYVM" "su -m root -c 'sh -s'" <<EOF
set -e
mkdir -p /usr/local/bin
for f in "$STAGE"/*; do install -m 755 "\$f" "/usr/local/bin/\$(basename \$f)"; done
echo "installed:"; ls -1 "$STAGE" | sed 's/^/  /'
EOF

echo "==> [3/5] install SERVER rc.d + rc.conf"
$SSH "$MYVM" "su -m root -c 'sh -s'" <<EOF
set -e
install -m 755 /mnt/bsdos/infra/rc.d/bsdos_core_server /usr/local/etc/rc.d/bsdos_core_server
sysrc bsdos_core_server_enable=YES
sysrc bsdos_core_server_listen_ip=${MYVM_IP}
sysrc bsdos_core_server_listen_port=7447
# Disable leftover bsdos_core rc.d if it exists (conflicts with bsdos_core_server)
sysrc bsdos_core_enable=NO 2>/dev/null || true
install -m 755 /mnt/bsdos/infra/rc.d/bsdos_lifecycled /usr/local/etc/rc.d/bsdos_lifecycled
sysrc bsdos_lifecycled_enable=YES
echo "rc.d installed"
EOF
fi  # OPT_ALL

if [ "$OPT_STREAMS" -eq 1 ]; then
echo "==> [4/5] set up 3-stream environment on myvm"
$SSH "$MYVM" "su -m root -c 'sh -s'" <<'EOF'
set -e

# Install Wayland compositor + apps + liblz4 (wayland-tunnel dep for LZ4 frames)
echo "-- pkg install cage foot chromium liblz4 --"
ASSUME_ALWAYS_YES=yes pkg install -q cage foot chromium liblz4 2>&1 | tail -5

# Create freebsd user (default spawn user in stream_manager.rs)
if ! id freebsd >/dev/null 2>&1; then
    pw useradd freebsd -m -s /bin/sh -G video,wheel
    echo "created: freebsd user"
else
    echo "exists: freebsd user"
    # Ensure freebsd user is in video group (needed for cage wlroots)
    pw usermod freebsd -G video,wheel 2>/dev/null || true
fi

# XDG runtime dirs for each stream (owned by freebsd, 700)
for app in appTerminal appBrowser appCowork; do
    mkdir -p "/tmp/bsdos-run/$app"
    chown freebsd:freebsd "/tmp/bsdos-run/$app"
    chmod 700 "/tmp/bsdos-run/$app"
done
echo "created: XDG runtime dirs /tmp/bsdos-run/{appTerminal,appBrowser,appCowork}"

# Home dir for chrome user-data-dir
mkdir -p /home/freebsd/.bsdos-chrome
chown -R freebsd:freebsd /home/freebsd

# Persistent Zenoh state dir
mkdir -p /var/db/bsdos
chown root:wheel /var/db/bsdos

echo "-- environment ready --"
EOF

echo "==> [5/5] configure BSDOS_AUTOSTREAM + restart bsdos_core_server"
$SSH "$MYVM" "su -m root -c 'sh -s'" <<'EOF'
set -e
# Update rc.d from 9p (has BSDOS_AUTOSTREAM support)
install -m 755 /mnt/bsdos/infra/rc.d/bsdos_core_server /usr/local/etc/rc.d/bsdos_core_server

# 3 autostreams: terminal + browser + cowork
# cowork requires electron39 — set to chrome as placeholder until electron is installed
sysrc bsdos_core_server_autostream="appTerminal:foot:,appBrowser:chrome:about:blank,appCowork:cowork:"

# Stop conflicting bsdos_core service if running
service bsdos_core stop 2>/dev/null || true

# Restart with new BSDOS_AUTOSTREAM
service bsdos_core_server restart 2>&1
sleep 5

echo "-- bsdos-core log (last 15 lines) --"
tail -15 /var/log/bsdos-core-server.log 2>/dev/null || echo "(no log yet)"
echo "-- running bsdos/cage processes --"
ps aux | grep -E "bsdos|cage|foot|chrome" | grep -v grep || echo "(none)"
EOF
fi  # OPT_STREAMS

echo "==> DONE."
if [ "$OPT_STREAMS" -eq 0 ]; then
  echo "    Note: run with --streams to configure 3-stream env (foot+chrome+cowork)."
fi

# ── electron42 deploy (separate, run after ports build finishes on dev VM) ──
# Usage: infra/scripts/deploy-bsdos-myvm.sh --electron42
# Builds electron42 pkg on dev VM (dev-vm) and installs on myvm (myvm).
# Run ONLY after: cd /usr/ports/devel/electron42 && WRKDIRPREFIX=... make install  (on dev-vm)
if echo "$*" | grep -q '\-\-electron42'; then
echo "==> [electron42] package from dev VM → install on myvm"
$SSH "$DEV" "su -m root -c 'sh -s'" <<EOF
set -e
cd /usr/ports/devel/electron42
WRKDIRPREFIX=/mnt/bsdos/artefacts/ports-build \
DISTDIR=/mnt/bsdos/artefacts/ports-distfiles \
make package 2>&1 | tail -3
PKG=\$(find /mnt/bsdos/artefacts/ports-build/usr/ports/packages/All -name 'electron42-*.pkg' 2>/dev/null | head -1)
if [ -z "\$PKG" ]; then
  # fallback: look in default PACKAGES dir
  PKG=\$(find /usr/ports/packages/All -name 'electron42-*.pkg' 2>/dev/null | head -1)
fi
[ -n "\$PKG" ] && cp -f "\$PKG" /mnt/bsdos/artefacts/myvm-bin/ && echo "staged: \$PKG" || echo "ERROR: electron42 pkg not found"
EOF

$SSH "$MYVM" "su -m root -c 'sh -s'" <<'EOF'
set -e
PKG=\$(ls /mnt/bsdos/artefacts/myvm-bin/electron42-*.pkg 2>/dev/null | head -1)
[ -n "\$PKG" ] || { echo "ERROR: no electron42 .pkg in staging"; exit 1; }
env ASSUME_ALWAYS_YES=yes pkg add "\$PKG" && echo "electron42 installed on myvm"
# Enable appCowork now that electron42 is available
sysrc bsdos_core_server_autostream="appTerminal:foot:,appBrowser:chrome:about:blank,appCowork:cowork:"
service bsdos_core_server restart
echo "appCowork enabled"
EOF
fi
