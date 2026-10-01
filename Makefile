# bsdOS — single entry point. No ad-hoc bash.
# Per-host values (IPs, key, data dir); not in git.
-include /etc/bsdos/hosts.env
#
# Architecture:
#   QEMU guest: FreeBSD 15.1 amd64 (KVM) / arm64 (device) — native + TCG
#   Host:       Linux (this machine) — UI layer runs here
#   Sources:    $(CURDIR)/proto/{broker,app} — Rust, std-only
#   Runtime:    /opt/proto/ in guest — jail dirs, base template, binaries
#
# Quick start:
#   make image-unpack   # decompress qcow2 (first time only)
#   make vm-start       # boot FreeBSD guest in background
#   make vm-wait        # wait until SSH is up
#   make vm-setup       # full guest setup (pkg + build + jail config)
#   make demo           # run jail prototype end-to-end

VM_IMG    ?= $(CURDIR)/freebsd15.qcow2
SEED_ISO  ?= $(CURDIR)/seed.iso
SSH_KEY   ?= $(CURDIR)/bsdos-key
SCRIPTS   := $(CURDIR)/infra/scripts
PROTO     := $(CURDIR)/proto
VM_SSH_PORT ?= 2222
VM_IPC_PORT ?= 9999

# x86_64 KVM (быстрая разработка — нативная скорость)
VM_X86_IMG   ?= $(CURDIR)/freebsd-x86-15.1.qcow2
FW_X86       ?= /usr/share/OVMF/OVMF_CODE_4M.fd
SPICE_PORT   ?= 5910

# Mac companion (host-side tools)
BSDOS_IP     ?= localhost
BSDOS_PORT   ?= 7447
INSTALL_PATH ?= /usr/local/bin

# Кросс-компиляция под Banana Pi M64 / PinePhone (aarch64 FreeBSD)
ZIG_TARGET   ?= aarch64-freebsd.15.1
RUST_TARGET  ?= aarch64-unknown-freebsd
ZIG_OPTIMIZE ?= ReleaseFast
RUST_FLAGS   ?= -C opt-level=3 -C target-cpu=cortex-a53
CROSS_ARCH   ?= aarch64
AARCH64_SYSROOT ?= /tmp/aarch64-sysroot
ZIG_LIBC     ?= /tmp/zig-bsdos-aarch64-libc.txt

# ── Squirrel multi-arch (SPEC_squirrel_rootfs.md) ───────────────────────────
SQUIRREL_VER ?= 0.1.3
ARTEFACTS    := $(CURDIR)/artefacts
SQUIRREL_IMG_AMD64   ?= $(ARTEFACTS)/bsdos-squirrel-v$(SQUIRREL_VER)-amd64.img.gz
SQUIRREL_IMG_AARCH64 ?= $(ARTEFACTS)/bsdos-squirrel-v$(SQUIRREL_VER)-aarch64.img.gz

# FreeBSD local build
FREEBSD_REL  ?= releng/15.1
SRC_DEPTH    ?= --depth 1
KERNCONF     ?= BSDOS-amd64
JOBS         ?= $(shell nproc 2>/dev/null || echo 4)
NAME         ?= baseline

.PHONY: help \
        image-download image-unpack image-download-x86 image-unpack-x86 \
        vm-start vm-stop vm-wait vm-ssh vm-status vm-x86-start vm-x86-stop vm-x86-reboot \
        vm-define vm-start-virt vm-stop-virt vm-spice vm-status-virt \
        vm-define-x86 vm-start-virt-x86 vm-stop-virt-x86 vm-spice-x86 vm-status-virt-x86 vm-logs-x86 \
        vm-setup vm-setup-pkg vm-setup-build vm-setup-jail vm-setup-nightly scp-sources vm-setup-fonts \
        build build-all build-broker build-app \
        build-zig build-zig-native deploy-zig run-zig-hal test-zig-hal test-hal-units \
        vm-setup-zig build-zig-in-guest \
        build-ui run-ui \
        demo demo-full demo-smoke jail-setup jail-teardown check-jail \
        setup-devfs demo-devfs vm-setup-devfs-advanced \
        vm-x86-wait vm-x86-spice \
        test-lifecycle test-app \
        lifecycle-log \
        vm-setup-zig \
        build-agent \
        run-agent \
        image-download-x86 \
        image-unpack-x86 \
        build-agent run-agent build-lifecycled run-lifecycled \
        vm-setup-zfs vm-setup-zenoh-net build-push-daemon build-jpk build-core run-core core-sub zenoh-token zenoh-rotate-token zenoh-cron-rotation test-all test-lifecycle lifecycle-log \
        vm-setup-phantom phantom-start \
        cross-build build-cluster \
        demo-x86 verify-jails setup-full \
        verify-binary-copy \
        check-data \
        test-app-verbose \
        agent-test agent-demo agent-build agent-jails agent-start \
        builder-up src-fetch patch-apply build-kernel kernel-swap \
        vconsole-check vm-snapshot vm-restore vm-load-virtio-console \
        vm-setup-p9fs vm-inject-startup \
        build-telemetry-client run-telemetry-client \
        mac-setup \
        cross-zig cross-zig-riscv64 cross-rust cross-kernel device-image \
        vm-setup-pf vm-update-adblock \
        jail-policy-apply \
        check-wayland-available check-app-packages \
        test-core-tls \
        vm-setup-drm \
        vm-setup-weston vm-start-weston vm-stop-weston vm-weston-log \
        vm-setup-labwc vm-start-labwc vm-stop-labwc vm-labwc-log \
        vm-setup-sway vm-start-sway vm-stop-sway vm-sway-log \
        vm-setup-cage vm-cage-log \
        demo-wayland wayland-tunnel-log \
        vm-backup vm-restore-backup \
        vm-tune-scheduler \
        wayland-tunnel-build wayland-tunnel-start wayland-tunnel-test wayland-input-test wayland-stream-test wayland-all-tests debug-wayland-build \
        stream-reader-build stream-reader-run wayland-status \
        vm-mount-wayland-jails vm-test-wayland-tunnel \
        check-drm \
        check-rust-version \
        gen-tls-certs vm-deploy-certs \
        bench \
        doctor logs reset \
        vm-launch-app vm-run-via-tunnel vm-install-firefox vm-install-foot vm-install-thunar \
        vm-setup-autostart vm-enable-autostart vm-disable-autostart vm-status-autostart \
        vm-pipeline-start vm-pipeline-stop vm-pipeline-restart vm-pipeline-status vm-pipeline-log \
        vm-fix-jail-dns vm-start-conduit \
        jail-freeze jail-thaw jail-lifecycle-status \
        jpk-build jpk-install jpk-info \
        pf-adblock-setup pf-adblock-update pf-adblock-status \
        beastie \
        phantom-setup phantom-start phantom-open phantom-stop phantom-status \
        conduit-setup conduit-start conduit-stop conduit-status conduit-logs \
        devfs-setup devfs-apply devfs-status \
        zfs-profile-create zfs-profile-load zfs-profile-unload zfs-profile-status zfs-wipe-keys \
        sema-check \
        bsdos-core-test metal-viewer-test unit-tests \
        cross-squirrel cross-squirrel-amd64 cross-squirrel-aarch64 \
        bsdos-build bsdos-build-amd64 bsdos-build-aarch64 \
        squirrel-bpi bpi-image bpi-flash \
        bsdos-smoke bsdos-smoke-amd64 bsdos-smoke-aarch64 \
        squirrel-boot squirrel-boot-amd64 squirrel-boot-aarch64 \
        test-2stream-e2e test-2stream-e2e-amd64 test-2stream-e2e-aarch64 \
        test-2stream-e2e-live \
        check-zenoh-routing \
        demo-2stream demo-2stream-remote \
        coverage-report bench-wayland-cpu \
        e2e-matrix

help:
	@echo "bsdOS — Targets (always go through these — no ad-hoc bash):"
	@echo ""
	@echo "  IMAGE"
	@echo "    image-download   — download FreeBSD 15.1 amd64 CLOUDINIT qcow2.xz"
	@echo "    image-unpack     — decompress + resize qcow2 (run once after download)"
	@echo ""
	@echo "  x86_64 KVM (быстрая разработка, ~10x быстрее ARM TCG)"
	@echo "    image-download-x86 — скачать FreeBSD 15.1 amd64 CLOUDINIT qcow2.xz (~400MB)"
	@echo "    image-unpack-x86   — распаковать + resize +12G"
	@echo "    vm-x86-start       — запустить x86_64 VM с KVM (нативная скорость)"
	@echo "    vm-x86-stop        — остановить x86_64 VM"
	@echo "                         cargo build: ~2-3s, zig build: ~1-2s, lifecycle test: <5s"
	@echo "    vm-x86-spice       — открыть SPICE дисплей VM (spice://127.0.0.1:5910)"
	@echo ""
	@echo "  VM (libvirt/SPICE — рекомендуется)"
	@echo "    vm-define        — зарегистрировать домен bsdos-dev в libvirt (один раз)"
	@echo "    vm-start-virt    — virsh start bsdos-dev"
	@echo "    vm-stop-virt     — virsh shutdown/destroy bsdos-dev"
	@echo "    vm-spice         — открыть SPICE-дисплей в virt-viewer"
	@echo "    vm-status-virt   — статус домена, SPICE порт, сетевой адрес"
	@echo ""
	@echo "  VM x86 KVM (libvirt с VirGL + DRI — нативная скорость + GL ускорение)"
	@echo "    vm-define-x86      — зарегистрировать домен bsdos-x86 в libvirt (один раз)"
	@echo "    vm-start-virt-x86  — virsh start bsdos-x86 (нативная x86_64 KVM)"
	@echo "    vm-stop-virt-x86   — virsh shutdown/destroy bsdos-x86"
	@echo "    vm-spice-x86       — открыть SPICE-дисплей с VirGL-ускорением (virt-viewer)"
	@echo "    vm-status-virt-x86 — статус домена, SPICE порт, сетевой адрес"
	@echo "    vm-logs-x86        — tail -f серийная консоль VM (artefacts/logs/serial-x86.log)"
	@echo ""
	@echo "  VM (прямой QEMU — fallback без дисплея)"
	@echo "    vm-start         — QEMU в фоне (serial → artefacts/logs/serial.log)"
	@echo "    vm-stop          — kill QEMU"
	@echo "    vm-wait          — ждать SSH"
	@echo "    vm-ssh           — SSH сессия (freebsd user)"
	@echo "    vm-status        — жив ли QEMU процесс"
	@echo ""
	@echo "  SETUP (run once after vm-wait)"
	@echo "    vm-setup         — full: scp-sources + vm-setup-pkg + vm-setup-build + vm-setup-jail"
	@echo "    scp-sources      — copy proto/ sources to guest /opt/proto-src"
	@echo "    vm-setup-pkg     — pkg bootstrap + install rust tmux in guest"
	@echo "    vm-setup-build   — cargo build broker + app in guest"
	@echo "    vm-setup-jail    — download base.txz, extract ro-template, copy jail configs"
	@echo "    vm-setup-fonts   — install JetBrains Mono font in guest for UI rendering"
	@echo ""
	@echo "  BUILD (rebuild after source changes)"
	@echo "    build            — build broker + app"
	@echo ""
	@echo "  UI (on Linux-host, Qt6 required)"
	@echo "                       with HomeScreen, LockScreen, NetworkPulse, Animations"
	@echo "    run-ui           — run UI (connects to broker on localhost:9999)"
	@echo "    vm-setup-fonts   — install JetBrains Mono font in guest for Neo-Brutalist UI"
	@echo ""
	@echo "  ZIG HAL"
	@echo "    vm-setup-zig       — install Zig 0.15.2 in guest via pkg (FreeBSD bundles libc)"
	@echo "    build-zig-in-guest — copy sys-daemon-zig/ + build natively in guest + deploy"
	@echo "    build-zig-native   — build HAL on Linux host (test compilation only)"
	@echo "    build-zig          — cross-compile on host (requires Zig master/0.15-dev)"
	@echo "    run-zig-hal        — start HAL daemon in guest"
	@echo "    test-zig-hal       — test: get_uptime + get_hostname via nc -U"
	@echo ""
	@echo "  GUEST AGENT (virtio-console, текстовый протокол)"
	@echo "    build-agent      — собрать bsdos-agent (virtio-console /dev/ttyV1.1)"
	@echo "    run-agent        — запустить агент внутри гостя"
	@echo ""
	@echo "  AGENT OPERATIONS (через bsdos-agent, без SSH)"
	@echo "    agent-demo     — полный demo через агент (HAL+broker+jails+app)"
	@echo "    agent-build    — пересобрать broker+app через агент (фоново)"
	@echo "    agent-jails    — setup jails через агент"
	@echo "    agent-start    — запустить HAL+broker+lifecycle через агент"
	@echo ""
	@echo "  LIFECYCLE (freeze/hibernate/kill jails)"
	@echo "    run-lifecycled   — запустить lifecycle daemon (Unix-сокет /var/run/bsdos-lifecycle.sock)"
	@echo "                       use: printf 'FREEZE appA\n' | nc -U /var/run/bsdos-lifecycle.sock"
	@echo ""
	@echo "  MATRIX HOMESERVER (в jail appMatrix)"
	@echo "    vm-fix-jail-dns           — починить DNS в jail appMatrix (resolv.conf)"
	@echo ""
	@echo "  ДОПОЛНИТЕЛЬНЫЕ КОМПОНЕНТЫ"
	@echo "    vm-setup-zfs     — создать ZFS pool + datasets в госте (bsdos/{apps,swap,jpk})"
	@echo "    build-core       — собрать bsdos-core (Zenoh + Cap'n Proto телеметрия)"
	@echo "    run-core         — запустить bsdos-core (publisher) в фоне"
	@echo "    core-sub         — подписаться на bsdos/telemetry в госте (Ctrl+C для выхода)"
	@echo "    run-telemetry-client    — запустить subscriber (PEER=tcp/localhost:7447 для явного подключения)"
	@echo "    test-all         — запустить все интеграционные тесты"
	@echo "    sema-check — moved to github.com/bzdOS/sema"
	@echo ""
	@echo "  PHANTOM BROWSER (Chromium в QEMU + CDP + Zenoh stream)"
	@echo "    vm-setup-phantom — pkg install chromium + создать /usr/local/bin/bsdos-chrome"
	@echo "    phantom-start    — запустить Chromium headless с CDP на :9222"
	@echo "                       CDP: http://localhost:9222/json"
	@echo "                       Stream: Zenoh bsdos/qemu/browser/display"
	@echo ""
	@echo "  КРОСС-КОМПИЛЯЦИЯ (Banana Pi M64 / aarch64-unknown-freebsd)"
	@echo "                       Zig: ZIG_TARGET=aarch64-freebsd.14.0 -Doptimize=ReleaseFast"
	@echo "                       Rust: RUSTFLAGS='-C opt-level=3 -C target-cpu=cortex-a53'"
	@echo "                       Требует: Zig 0.15+ и Rust nightly + -Z build-std"
	@echo "                       Выход: artefacts/cross/aarch64/bin/bsdos-hal"
	@echo "    cross-zig-riscv64 — кросс-компилировать Zig HAL для RISC-V 64"
	@echo "                       CROSS_ARCH=riscv64"
	@echo "                       Требует: cargo-zigbuild и Rust nightly"
	@echo "                       CROSS_ARCH=aarch64|riscv64 KERNCONF=BSDOS-arm64"
	@echo ""
	@echo "  БИЗДОС-КЛАСТЕР (YDB + Zenoh + ZFS)"
	@echo "    build-cluster    — собрать bpc-coordinator (YDB metadata + Zenoh transport + ZFS storage)"
	@echo "                       Требует: Rust 1.70+ (tokio, zenoh)"
	@echo "                       Выход: cluster/target/release/bpc-coordinator"
	@echo ""
	@echo "  DEVFS (kernel-enforced device visibility)"
	@echo "    setup-devfs            — install custom devfs rules in guest (ruleset 10/11)"
	@echo "    vm-setup-devfs-advanced — per-app rulesets (20–60) for audio/camera/modem/display"
	@echo "    demo-devfs             — show /dev/bpf visibility difference per jail"
	@echo ""
	@echo "  PF AD-BLOCK & NETWORK POLICY (Feature 6: Privacy, Phase 1+)"
	@echo "    vm-setup-pf         — install PF rules + initialize ad-block list in guest"
	@echo "    vm-update-adblock    — fetch Steven Black hosts list and reload PF table"
	@echo "    jail-policy-apply    — read network-policy.json, generate pf.conf, load rules (Phase 1)"
	@echo ""
	@echo "  BACKUP & RESTORE (ZFS, Phase 1)"
	@echo "    vm-backup                — create ZFS snapshot + send to /tmp/bsdos-backup-*.zfs"
	@echo "                               Usage: make vm-backup NAME=daily (default)"
	@echo "    vm-restore-backup        — restore ZFS snapshot from /tmp/bsdos-backup-*.zfs"
	@echo "                               Usage: make vm-restore-backup BACKUP_FILE=/tmp/... [FORCE=1]"
	@echo ""
	@echo "  SCHEDULER TUNING (FreeBSD ULE, mobile device optimization)"
	@echo "    vm-tune-scheduler        — tune kernel Hz + sysctl for power/performance trade-off"
	@echo "                               Usage: make vm-tune-scheduler POWER_MODE={performance|normal|powersave}"
	@echo "                               Default: normal (Hz=100, balanced)"
	@echo "                               performance: Hz=1000 (interactive, screen-on)"
	@echo "                               powersave: Hz=15 (battery mode, screen-off)"
	@echo ""
	@echo "  DEMO / TEST"
	@echo "    demo-smoke       — smoke test: broker up, jail setup, nc -U /bus/bus.sock, verify response"
	@echo "    demo             — full: appA (ip4=inherit) vs appB (ip4=disable), broker log"
	@echo "    demo-full        — showcase: Zenoh telemetry, jail isolation, Wayland pipeline, freeze/thaw"
	@echo "    demo-x86         — полный demo на x86 KVM (HAL+broker+nc+jails+app)"
	@echo "    verify-jails     — проверить что appA/appB jails запущены"
	@echo "    setup-full       — полный атомарный setup свежей x86 VM"
	@echo "    jail-setup       — jailmgr setup-all"
	@echo "    jail-teardown    — jailmgr teardown-all"
	@echo "    test-lifecycle   — FREEZE/STATUS/THAW/HIBERNATE тесты lifecycled daemon"
	@echo ""
	@echo "  virtio-console + QMP (PLAN-virtio-console.md)"
	@echo "    vconsole-check  — Phase 0: проверить /dev/ttyV* + echo round-trip через socat"
	@echo "    vm-snapshot     — QMP savevm (NAME=good make vm-snapshot) — мгновенный checkpoint"
	@echo "    vm-restore      — QMP loadvm (NAME=good make vm-restore)  — откат к baseline за <5с"
	@echo ""
	@echo "  FreeBSD local build (PLAN-freebsd-local-build.md)"
	@echo "    builder-up      — проверить готовность VM (git, /obj, /usr/src)"
	@echo "    src-fetch       — git clone releng/15.1 в /usr/src (FREEBSD_REL=releng/15.1)"
	@echo "    patch-apply     — scp freebsd-patches/conf/BSDOS-* + применить *.patch"
	@echo ""
	@echo "  WAYLAND COMPOSITORS (Phase 0: fbdev testing; Phase 1+: DRM/Mali backend)"
	@echo "    check-wayland-available — query FreeBSD pkg for available Wayland compositors"
	@echo ""
	@echo "    WESTON (reference implementation, fbdev + DRM)"
	@echo "      vm-setup-weston   — install wayland + weston + config (fbdev backend)"
	@echo "      vm-start-weston   — launch weston in background (720x1440 @ 30fps)"
	@echo "      vm-stop-weston    — pkill -f weston"
	@echo "      vm-weston-log     — tail -50 /tmp/weston.log"
	@echo ""
	@echo "    LABWC (minimal stacking, GTK-native, ~20MB memory)"
	@echo "      vm-setup-labwc    — install labwc + minimal rc.xml config"
	@echo "      vm-start-labwc    — launch labwc in background"
	@echo "      vm-stop-labwc     — pkill -f labwc"
	@echo "      vm-labwc-log      — tail -50 /tmp/labwc.log"
	@echo ""
	@echo "    SWAY (i3-like tiling, keyboard-first, scriptable)"
	@echo "      vm-setup-sway     — install sway + swaylock + swayidle + config"
	@echo "      vm-start-sway     — launch sway in background"
	@echo "      vm-stop-sway      — pkill -f sway"
	@echo "      vm-sway-log       — tail -50 /tmp/sway.log"
	@echo ""
	@echo "    CAGE (kiosk mode, single-app Wayland, lightweight)"
	@echo "      vm-setup-cage     — install cage + wf-recorder + grim + sway"
	@echo "      vm-cage-log       — tail -20 /tmp/cage.log"
	@echo ""
	@echo "  AUTOSTART (rc.d services — бэкграунд компоненты на boot)"
	@echo "    vm-setup-autostart       — deploy rc.d scripts (bsdos-core, wayland-tunnel, cage)"
	@echo "                               services disabled by default"
	@echo "    vm-enable-autostart      — enable all services to start at boot"
	@echo "    vm-disable-autostart     — disable all services (keep scripts)"
	@echo "    vm-status-autostart      — show current rc.conf.d/bsdos-autostart settings"
	@echo ""
	@echo "  ДИАГНОСТИКА"
	@echo "    doctor    — одношаговый снимок состояния: VM, Agent, Jails, Mem, QMP, p9fs"
	@echo "    logs      — показать последние 10 строк всех логов (LINES=N для другого количества)"
	@echo "    reset     — быстрый откат: teardown jails → restart HAL/broker (без reboot)"
	@echo ""
	@echo "  CHIMP v0.2 (Banana Pi M64 / Allwinner A64 — U-Boot SD image, UNTESTED)"
	@echo "                    Usage: make bpi-image BPI_ROOTFS=<dir> BPI_OUT=<out.img>"
	@echo "    bpi-flash     — dd image → SD card (GUARDED: needs SD=/dev/daX CONFIRM=yes)"
	@echo "                    Usage: make bpi-flash SD=/dev/da0 CONFIRM=yes [BPI_OUT=...]"
	@echo "                    See https://github.com/bzdOS/bzdOS/blob/main/docs/BPI-M64-BOOT.md (boot chain + validation checklist)"
	@echo ""
	@echo "  MAC COMPANION (Host utilities for MacBook/Linux)"
	@echo "    mac-setup              — install & build telemetry-client"
	@echo "                             (automatically detects Rust, installs symlinks)"
	@echo "    run-telemetry-client   — subscribe to bsdos/telemetry on device (PEER=tcp/IP:7447)"
	@echo ""
	@echo "  Usage: BSDOS_IP=192.168.1.42 BSDOS_PORT=7447 make mac-setup"
	@echo ""
	@echo "Vars: VM_IMG=$(VM_IMG)"
	@echo "      SSH_KEY=$(SSH_KEY)  VM_SSH_PORT=$(VM_SSH_PORT)"

# ── Image ─────────────────────────────────────────────────────────────────────

image-download:
	$(SCRIPTS)/image-download.sh

image-unpack:
	VM_IMG=$(VM_IMG) $(SCRIPTS)/image-unpack.sh

image-download-x86:
	$(SCRIPTS)/image-download-x86.sh

image-unpack-x86:
	$(SCRIPTS)/image-unpack-x86.sh

vm-x86-start:
	@mkdir -p $(CURDIR)/artefacts/logs
	$(MAKE) tunnel-cleanup
	VM_X86_IMG=$(VM_X86_IMG) FW_X86=$(FW_X86) SEED_ISO=$(SEED_ISO) \
	    LOG=$(CURDIR)/artefacts/logs/serial-x86.log \
	    VM_SSH_PORT=$(VM_SSH_PORT) VM_IPC_PORT=$(VM_IPC_PORT) \
	    $(SCRIPTS)/vm-x86-start.sh

vm-x86-stop:
	$(SCRIPTS)/vm-x86-stop.sh

vm-x86-reboot:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-x86-reboot.sh

vm-x86-wait:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) \
	    LOG=$(CURDIR)/artefacts/logs/serial-x86.log \
	    $(SCRIPTS)/vm-x86-wait.sh

vm-x86-spice:
	SPICE_PORT=$(SPICE_PORT) $(SCRIPTS)/vm-x86-spice.sh

# ── VM (libvirt/SPICE) ───────────────────────────────────────────────────────

vm-define:
	$(SCRIPTS)/vm-define.sh

vm-start-virt:
	$(SCRIPTS)/vm-start-virt.sh

vm-stop-virt:
	$(SCRIPTS)/vm-stop-virt.sh

vm-spice:
	$(SCRIPTS)/vm-spice.sh

vm-status-virt:
	$(SCRIPTS)/vm-status-virt.sh

# ── VM x86 (libvirt/SPICE с VirGL + DRI) ──────────────────────────────────────

vm-define-x86:
	$(SCRIPTS)/vm-define-x86.sh

vm-start-virt-x86:
	$(SCRIPTS)/vm-start-virt-x86.sh

vm-stop-virt-x86:
	$(SCRIPTS)/vm-stop-virt-x86.sh

vm-spice-x86:
	$(SCRIPTS)/vm-spice-x86.sh

vm-status-virt-x86:
	$(SCRIPTS)/vm-status-virt-x86.sh

vm-logs-x86:
	$(SCRIPTS)/vm-logs-x86.sh

# ── VM (прямой QEMU) ──────────────────────────────────────────────────────────

vm-start:
	@mkdir -p $(CURDIR)/artefacts/logs
	VM_IMG=$(VM_IMG) SEED_ISO=$(SEED_ISO) FW=$(FW) \
	    LOG=$(CURDIR)/artefacts/logs/serial.log \
	    VM_SSH_PORT=$(VM_SSH_PORT) VM_IPC_PORT=$(VM_IPC_PORT) \
	    $(SCRIPTS)/vm-start.sh

vm-stop:
	$(SCRIPTS)/vm-stop.sh

vm-wait:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-wait-ssh.sh

vm-ssh:
	@ssh -p $(VM_SSH_PORT) -i $(SSH_KEY) \
	    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	    freebsd@localhost

vm-status:
	@pgrep -x qemu-system-aarch64 >/dev/null 2>&1 \
	    && echo "VM: running (QEMU pid=$$(pgrep -x qemu-system-aarch64))" \
	    || echo "VM: stopped"

# ── Setup ─────────────────────────────────────────────────────────────────────

vm-setup: scp-sources vm-setup-pkg vm-setup-build vm-setup-jail
	@echo "=== Guest setup complete ==="

scp-sources:
	scp -P $(VM_SSH_PORT) -i $(SSH_KEY) \
	    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	    -r $(PROTO)/broker $(PROTO)/app $(PROTO)/jail.conf $(PROTO)/jailmgr.sh \
	    freebsd@localhost:/opt/proto-src/

vm-setup-pkg:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-setup-pkg.sh

vm-setup-build:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-setup-build.sh

vm-setup-jail:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-setup-jail.sh

vm-setup-nightly:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-setup-nightly.sh

vm-setup-fonts:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-setup-fonts.sh

# ── Launch Applications in Jails ──────────────────────────────────────────────

vm-launch-app:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) \
	    APP=$(APP) JAIL=$(JAIL) \
	    $(SCRIPTS)/vm-launch-app.sh

vm-run-via-tunnel:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) \
	    APP=$(APP) \
	    $(SCRIPTS)/vm-run-via-tunnel.sh

vm-install-firefox:
	APP=firefox JAIL=appBrowser $(MAKE) vm-launch-app

vm-install-foot:
	APP=foot JAIL=appTerminal $(MAKE) vm-launch-app

vm-install-thunar:
	APP=thunar JAIL=appFiles $(MAKE) vm-launch-app

# ── Build ─────────────────────────────────────────────────────────────────────

build: build-broker build-app

build-all:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/build-all.sh

# ── UI ────────────────────────────────────────────────────────────────────

run-ui:
	$(SCRIPTS)/run-ui.sh

# ── Frame Capture (Zenoh display streaming) ────────────────────────────────

build-frame-capture:
	cargo build --release -p bsdos-frame-capture

# Publisher: runs on FreeBSD VM, captures frames → Zenoh
# Usage: make vm-frame-capture [CAPTURE_FPS=30] [ZENOH_PEER=tcp/host:7447]
vm-frame-capture:
	cd $(CURDIR) && . infra/scripts/_agent.sh && agent_exec "cd /opt/proto-src && CAPTURE_FPS=15 /opt/proto-src/target/release/bsdos-frame-capture"

# Viewer: runs on host (Mac/Linux), displays frames from Zenoh
# Usage: make frame-viewer [PEER=tcp/vm-ip:7447]
frame-viewer:
	cargo run --release --bin bsdos-frame-viewer -- tcp/localhost:7447

# ── Zig HAL ───────────────────────────────────────────────────────────────

build-zig:
	$(SCRIPTS)/build-zig.sh

build-zig-native:
	$(SCRIPTS)/build-zig-native.sh

deploy-zig:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/deploy-zig.sh

# ── Deploy bsdos-core + wayland-tunnel to dev-vm via guest-agent (no SSH inside recipe) ──
# Transport: /tmp/bsdos-agent-vport.sock (virtio-console host side).
# Builds+installs BOTH halves of the WLSTREAM_* env-var contract together —
# see https://github.com/bzdOS/bzdOS/blob/main/docs/STREAM-DEPLOY-CONTRACT.md. deploy-streaming/deploy-dev-vm kept as aliases.
deploy-stream-pipeline deploy-streaming deploy-dev-vm:
	$(SCRIPTS)/deploy-dev-vm.sh

run-zig-hal:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/run-zig-hal.sh

test-zig-hal:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/test-zig-hal.sh

test-hal-units:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/test-hal-units.sh

# Guest-native Zig build (Zig 0.15.2 from FreeBSD pkg — bundles FreeBSD libc)
# Preferred over host cross-compile which requires Zig master (0.15-dev)
vm-setup-zig:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-setup-zig.sh

build-zig-in-guest:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/build-zig-in-guest.sh

# ── Guest Agent ───────────────────────────────────────────────────────────────

build-agent:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/build-agent.sh

run-agent:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/run-agent.sh

# ── Lifecycle ──────────────────────────────────────────────────────────────────

run-lifecycled:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/run-lifecycled.sh

# ── Дополнительные компоненты ─────────────────────────────────────────────────

vm-setup-zfs:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-setup-zfs.sh

vm-setup-zenoh-net:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-setup-zenoh-net.sh

build-core:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/build-core.sh

run-core:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/run-core.sh

core-sub:
	@printf 'Subscribing to bsdos/telemetry (Ctrl+C to stop)...\n'
	cd $(CURDIR) && . infra/scripts/_agent.sh && agent_exec "/usr/local/bin/bsdos-core-sub"

zenoh-token:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/zenoh-token.sh

zenoh-rotate-token:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/zenoh-rotate-token.sh

zenoh-cron-rotation:
	@echo "Adding daily token rotation to crontab..."
	@(crontab -l 2>/dev/null; echo "0 4 * * * make -C $(CURDIR) zenoh-rotate-token >> /var/log/bsdos-token-rotation.log 2>&1") | sort -u | crontab -
	@echo "Rotation scheduled: daily at 04:00"
	@crontab -l | grep zenoh

test-all:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/test-all.sh

test-lifecycle:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/test-lifecycle.sh

# ── Coupling stack (SPEC_coupling_v1) — host-first dev/test ───────────────────
# Portable core (lease/lock/fence/CAS/CRDT/queue/proto) builds+tests on the host
# (Linux buildhost), same pattern as build-telemetry-client. FreeBSD-target = dev-vm.
# FreeBSD-target build + tests on dev-VM dev-vm (orchestrator-run; agent_exec like core-sub)
run-telemetry-client:
	PEER="$(PEER)" $(SCRIPTS)/run-telemetry-client.sh

# ── Mac Companion (Host-side tools) ──────────────────────────────────────────

mac-setup:
	BSDOS_IP=$(BSDOS_IP) BSDOS_PORT=$(BSDOS_PORT) INSTALL_PATH=$(INSTALL_PATH) $(SCRIPTS)/mac-setup.sh

test-app:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/test-app.sh

test-app-verbose:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/test-app-verbose.sh

test-agent:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/test-agent.sh

agent-test:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) \
	    AGENT_VPORT_SOCK=/tmp/bsdos-agent-vport.sock \
	    $(SCRIPTS)/agent-test.sh

agent-demo:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/agent-ops.sh demo

agent-build:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/agent-ops.sh build

agent-jails:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/agent-ops.sh jails

agent-start:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/agent-ops.sh start

verify-jails:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/verify-jails.sh

demo-x86: run-zig-hal demo
	@echo "x86 demo complete"

setup-full: vm-setup vm-setup-zfs vm-setup-zig build-zig-in-guest run-zig-hal build-lifecycled run-lifecycled
	@echo "=== Full setup complete ==="

lifecycle-log:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/lifecycle-log.sh

# ── Phantom Browser ───────────────────────────────────────────────────────────

vm-setup-phantom:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-setup-phantom.sh

# ── Кросс-компиляция ──────────────────────────────────────────────────────────

# ── Squirrel cross-compile (per SPEC §11.3) ────────────────────────────────
# Builds ALL bsdOS components (Rust: bsdos-core + lifecycled, Zig: bsdos-hal + wayland-tunnel)
# for a single target arch. Output goes to artefacts/squirrel/<arch>/.

cross-squirrel: cross-squirrel-amd64 cross-squirrel-aarch64

# ── bsdOS rootfs build (per SPEC §4-§5) ─────────────────────────────────────
# Orchestrator script runs 7 stages: base fetch → pkg → Rust → Zig → configs → mkimg → smoke
# ── Chimp (v0.2) — Banana Pi M64 (Allwinner A64) bootable SD image ──────────
# squirrel-bpi builds the full rootfs for machine 'bpi-m64'; Stage 6 of
# bsdos-build.sh detects platform=bpi_m64 and emits a U-Boot sunxi image via
# bpi-image.sh instead of the UEFI/BIOS mkimg path. UNTESTED until hardware
# (a hub task). Recipe is a local command — run remotely via: ssh box 'make squirrel-bpi'.
# bpi-image — call bpi-image.sh directly on an already-staged rootfs.
#   Usage: make bpi-image ROOTFS=<staged-rootfs-dir> BPI_OUT=<out.img>
#   Defaults to the bsdos-build aarch64 work rootfs + artefacts output.
BPI_ROOTFS ?= $(HOME)/.cache/bsdos-build/aarch64/work/rootfs
BPI_OUT    ?= $(ARTEFACTS)/bsdos-chimp-bpi-m64.img
# bpi-flash — dd an image onto an SD card. GUARDED: requires SD=/dev/daX AND
#   CONFIRM=yes. NEVER guesses the device — a wrong device node destroys disks.
#   Usage: make bpi-flash SD=/dev/da0 CONFIRM=yes [BPI_OUT=<img>]
bpi-flash:
	@if [ -z "$(SD)" ]; then \
	    echo "REFUSING: set SD=/dev/daX (the SD-card device node) explicitly."; \
	    echo "  This target NEVER guesses the device — a wrong node destroys disks."; \
	    echo "  Usage: make bpi-flash SD=/dev/da0 CONFIRM=yes [BPI_OUT=$(BPI_OUT)]"; \
	    exit 1; \
	fi
	@if [ ! -f "$(BPI_OUT)" ]; then \
	    echo "REFUSING: image not found: $(BPI_OUT) (build it: make squirrel-bpi / make bpi-image)"; \
	    exit 1; \
	fi
	@if [ "$(CONFIRM)" != "yes" ]; then \
	    echo "WARNING: about to OVERWRITE $(SD) with $(BPI_OUT) — ALL DATA ON $(SD) WILL BE LOST."; \
	    echo "  Re-run with CONFIRM=yes to proceed:"; \
	    echo "    make bpi-flash SD=$(SD) CONFIRM=yes BPI_OUT=$(BPI_OUT)"; \
	    exit 1; \
	fi
	@echo "=== Flashing $(BPI_OUT) → $(SD) (dd bs=1m) ==="
	@echo "    NB: no conv=sync — it zero-pads short reads (harmless for a file, FATAL through a gunzip|dd pipe)."
	dd if="$(BPI_OUT)" of="$(SD)" bs=1m
	@echo "=== Done. Insert SD into BPI-M64, wire 3.3V UART @115200. See https://github.com/bzdOS/bzdOS/blob/main/docs/BPI-M64-BOOT.md ==="

# ── bsdOS smoke test (boots in QEMU, verifies bsdos-core + Zenoh) ────────
# ── Squirrel interactive boot (foreground QEMU for debugging) ──────────────
squirrel-boot:
	@echo "Usage: make squirrel-boot-amd64 OR squirrel-boot-aarch64"

squirrel-boot-amd64:
	@echo "Booting Squirrel amd64 (Ctrl+A X to quit QEMU)..."
	qemu-system-x86_64 -m 2G -smp 4 -machine q35 -cpu host \
	    -drive file=$(SQUIRREL_IMG_AMD64),format=raw,if=virtio \
	    -device virtio-net-pci,netdev=net0 -netdev user,id=net0,hostfwd=tcp::7447-:7447 \
	    -nographic -serial stdio

squirrel-boot-aarch64:
	@echo "Booting Squirrel aarch64 (Ctrl+A X to quit QEMU)..."
	qemu-system-aarch64 -m 2G -smp 4 -machine virt -cpu cortex-a72 \
	    -drive file=$(SQUIRREL_IMG_AARCH64),format=raw,if=virtio \
	    -device virtio-net-pci,netdev=net0 -netdev user,id=net0,hostfwd=tcp::7447-:7447 \
	    -nographic -serial stdio

# ── Lima / GPU display (Porcupine v0.3 — PinePhone Pro) ──────────────────────

## Phase A: fbdev MVP (weston fbdev-backend, Mesa softpipe, no DRM needed)
## Installs: graphics/weston graphics/mesa-libs x11/libdrm (for Mesa headers only)
display-deps-porcupine:
	@echo "=== Install display deps on Porcupine (FreeBSD 15.1 aarch64) ==="
	@echo "ssh freebsd@<porcupine-ip> 'pkg install -y weston mesa-libs libdrm evdev-proto'"

## Phase C: virgl in QEMU Squirrel (virtio-gpu acceleration)
display-squirrel-virgl:
	@echo "=== Squirrel: enable virgl in QEMU (virtio-gpu + WLR_BACKENDS=drm) ==="
	@echo "Requires: WLR_BACKENDS=drm MESA_LOADER_DRIVER_OVERRIDE=virpipe"

## Build HAL for Porcupine
build-hal-aarch64:
	@echo "=== Build GPU HAL for aarch64-freebsd ==="
	cd hal && zig build -Dtarget=aarch64-freebsd.15.1 -Doptimize=ReleaseFast $(ZIG_PLATFORM_FLAG)

## Setup fbdev display on Porcupine
# ── 2-stream demo (per SPEC_2stream_squirrel.md) ───────────────────────────
test-2stream-e2e:
	$(SCRIPTS)/test-2stream-e2e.sh

test-2stream-e2e-amd64:
	$(SCRIPTS)/test-2stream-e2e.sh amd64

test-2stream-e2e-aarch64:
	$(SCRIPTS)/test-2stream-e2e.sh aarch64

# test-2stream-e2e-live: check production myvm ($(BSDOS_MYVM_IP)) without booting QEMU.
# Verifies bsdos-core TCP port, Zenoh session (if bsdos-core-sub is built), and dev-vm relay.
# Run from host after 'make demo-2stream' confirms sockets are up.
test-2stream-e2e-live:
	$(SCRIPTS)/test-2stream-e2e.sh --live

# e2e-matrix: self-contained end-to-end test harness for matrix-hs.
# Builds matrix-hs --features cluster if needed, spins 2 nodes on localhost,
# runs all assertions (single-node + distributed), tears down cleanly.
# Live mode: MATRIX_A_URL=http://... MATRIX_B_URL=http://... make e2e-matrix
# hubd-matrix-bridge-install: install + enable the hubd→Matrix bridge (task #171).
# Installs the two systemd units, daemon-reloads, and enables+starts both services.
# Prereq: artefacts/matrix-hs-bridge.env exists with MATRIX_HS_* + HUBD_BRIDGE_* creds
# (gitignored) and the matrix-hs binary at $(BSDOS_ROOT)/target/release/matrix-hs.
hubd-matrix-bridge-install:
	install -m 644 -D $(CURDIR)/infra/systemd/matrix-hs.service /etc/systemd/system/matrix-hs.service
	install -m 644 -D $(CURDIR)/infra/systemd/hubd-matrix-bridge.service /etc/systemd/system/hubd-matrix-bridge.service
	systemctl daemon-reload
	systemctl enable --now matrix-hs.service hubd-matrix-bridge.service
	@echo "=== hubd→Matrix bridge installed ==="
	@echo "matrix-hs: $$(systemctl is-active matrix-hs.service) on 127.0.0.1:8448"
	@echo "bridge:    $$(systemctl is-active hubd-matrix-bridge.service)"
	@echo "Read on phone: Element/FluffyChat → http://$(BSDOS_DEV_IP):8448, join !bsdos-reports:localhost"

# check-zenoh-routing: smoke-test dev-vm→myvm Zenoh routing from the host.
# TCP checks are instant; bsdos-core-sub probe requires binary to be built on dev-vm first.
check-zenoh-routing:
	$(SCRIPTS)/check-zenoh-routing.sh

# demo-2stream: run from host — ssh into myvm (myvm) and execute demo-2stream-remote.
# SSH must NOT be called from inside make recipes per project rules; this target IS
# the ssh invocation (run from the host shell, not from inside another make recipe).
demo-2stream:
	@echo "=== 2-stream demo (terminal + browser) on myvm ($(BSDOS_MYVM_IP)) ==="
	ssh -i $(SSH_KEY) \
	    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	    -o ControlMaster=auto \
	    -o "ControlPath=/tmp/bsdos-ssh-ctl-%r@%h:%p" \
	    -o ControlPersist=120 \
	    freebsd@$(BSDOS_MYVM_IP) \
	    'su -m root -c "gmake -C /mnt/bsdos demo-2stream-remote"'

# demo-2stream-remote: LOCAL target — runs on myvm ($(BSDOS_MYVM_IP)) directly.
# Restarts bsdos_core_server with 2-stream AUTOSTREAM, polls for stream sockets,
# then verifies Zenoh is listening and bsdos-core process is alive.
# No ssh inside this recipe.
# ── Биздос-Кластер ────────────────────────────────────────────────────────────

build-cluster:
	cd $(CURDIR)/cluster && cargo build --release

# ── Demo / Test ───────────────────────────────────────────────────────────────

demo-smoke:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/demo-smoke.sh

demo:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/demo-run.sh

demo-full:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/demo-full.sh

jail-setup:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/jail-setup.sh

jail-teardown:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/jail-teardown.sh

check-jail:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/check-jail.sh

# ── DEVFS ─────────────────────────────────────────────────────────────────────

setup-devfs:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-setup-devfs.sh

vm-setup-devfs-advanced:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-setup-devfs-advanced.sh

demo-devfs:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/demo-devfs.sh

verify-binary-copy:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/verify-binary-copy.sh

check-data:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/check-data.sh

# ── FreeBSD local build (PLAN-freebsd-local-build.md) ────────────────────────

builder-up:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/builder-up.sh

src-fetch:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) \
	    FREEBSD_REL=$(FREEBSD_REL) SRC_DEPTH="$(SRC_DEPTH)" \
	    $(SCRIPTS)/src-fetch.sh

patch-apply:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/patch-apply.sh

# ── virtio-console + QMP ─────────────────────────────────────────────────────

vconsole-check:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) \
	    AGENT_VPORT_SOCK=/tmp/bsdos-agent-vport.sock \
	    $(SCRIPTS)/vconsole-check.sh

vm-load-virtio-console:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-load-virtio-console.sh

vm-snapshot:
	QMP_SOCK=/tmp/bsdos-qmp.sock NAME=$(NAME) $(SCRIPTS)/vm-snapshot.sh

vm-restore:
	QMP_SOCK=/tmp/bsdos-qmp.sock NAME=$(NAME) $(SCRIPTS)/vm-restore.sh

vm-setup-p9fs:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) \
	    P9FS_MOUNTPOINT=/mnt/bsdos P9FS_TAG=bsdos \
	    $(SCRIPTS)/vm-setup-p9fs.sh

vm-inject-startup:
	VM_X86_IMG=$(VM_X86_IMG) $(SCRIPTS)/vm-inject-startup.sh

# ── PF Network Policy (Phase 1+) ──────────────────────────────────────────────

jail-policy-apply: vm-wait
	@echo "=== Applying network policy from proto/network-policy.json ==="
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) \
	    POLICY_JSON=$(PROTO)/network-policy.json \
	    $(SCRIPTS)/apply-network-policy.sh

# ── Performance Benchmarking ──────────────────────────────────────────────────

bench:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/bench.sh

# ── Диагностика ───────────────────────────────────────────────────────────────

doctor:
	$(SCRIPTS)/doctor.sh

logs:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) LINES=$(LINES) $(SCRIPTS)/logs.sh

reset:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/reset.sh

# ── Кросс-компиляция для device targets ────────────────────────────────────────

cross-zig-riscv64:
	CROSS_ARCH=riscv64 $(MAKE) -f $(MAKEFILE_LIST) cross-zig

# ── PF ad-block (Feature 6: Privacy) ───────────────────────────────────────────

vm-setup-pf:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-setup-pf.sh

vm-update-adblock:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-update-adblock.sh

# ── Weston Compositor (Phase 0+) ───────────────────────────────────────────────

check-wayland-available:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/check-wayland-available.sh

check-app-packages:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/check-app-packages.sh

vm-setup-weston:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-setup-weston.sh

vm-start-weston:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-start-weston.sh

vm-stop-weston:
	@cd $(CURDIR) && . infra/scripts/_agent.sh && agent_exec "pkill -f weston || true" 2>&1 | head -3 || true

vm-weston-log:
	@cd $(CURDIR) && . infra/scripts/_agent.sh && agent_exec "tail -50 /tmp/weston.log 2>/dev/null || echo 'Log not available yet'" || true

# ── labwc Compositor (minimal stacking, Phase 0) ────────────────────────────────

vm-setup-labwc:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-setup-labwc.sh

vm-start-labwc:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-start-labwc.sh

vm-stop-labwc:
	@cd $(CURDIR) && . infra/scripts/_agent.sh && agent_exec "pkill -f 'labwc' || true" 2>&1 | head -3 || true

vm-labwc-log:
	@cd $(CURDIR) && . infra/scripts/_agent.sh && agent_exec "tail -50 /tmp/labwc.log 2>/dev/null || echo 'Log not available yet'" || true

# ── Sway Compositor (i3-like tiling, Phase 0+) ─────────────────────────────────

vm-setup-sway:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-setup-sway.sh

vm-start-sway:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-start-sway.sh

vm-stop-sway:
	@cd $(CURDIR) && . infra/scripts/_agent.sh && agent_exec "pkill -f 'sway' || true" 2>&1 | head -3 || true

vm-sway-log:
	@cd $(CURDIR) && . infra/scripts/_agent.sh && agent_exec "tail -50 /tmp/sway.log 2>/dev/null || echo 'Log not available yet'" || true

host-setup-zenoh-ip:
	$(SCRIPTS)/host-setup-zenoh-ip.sh

vm-fix-jail-dns:
	chmod +x $(SCRIPTS)/vm-fix-jail-dns.sh && \
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-fix-jail-dns.sh

vm-check-appmatrix-jail:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) /bin/sh -c '. infra/scripts/_ssh.sh && ssh_root "jls -j appMatrix && jexec appMatrix ps aux && echo Logs: && jexec appMatrix tail /tmp/conduit.log 2>/dev/null || echo No logs"'

vm-check-conduit-build:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) /bin/sh -c '. infra/scripts/_ssh.sh && ssh_root "echo [Host view of data dir:] && ls -la /opt/proto/data/appMatrix/bin/ 2>/dev/null | head -5 || echo EMPTY; echo [From host:] && test -f /opt/proto/data/appMatrix/bin/conduit && ls -lh /opt/proto/data/appMatrix/bin/conduit || echo MISSING"'

vm-show-conduit-content:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) /bin/sh -c '. infra/scripts/_ssh.sh && ssh_root "echo Content of conduit binary: && cat /opt/proto/data/appMatrix/bin/conduit"'

vm-verify-rust-available:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) /bin/sh -c '. infra/scripts/_ssh.sh && ssh_root "jexec appMatrix which rustc && jexec appMatrix rustc --version || echo rustc not found"'

vm-install-simple-nc-mock:
	chmod +x $(SCRIPTS)/vm-install-simple-nc-mock.sh && \
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-install-simple-nc-mock.sh

vm-check-jail-paths:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) /bin/sh -c '. infra/scripts/_ssh.sh && ssh_root "echo Host view: && ls -la /opt/proto/data/appMatrix/bin/ && echo Jail view: && jexec appMatrix ls -la /data/bin/ 2>/dev/null || echo jail paths differ"'

vm-check-server-script:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) /bin/sh -c '. infra/scripts/_ssh.sh && ssh_root "echo conduit-server.sh: && cat /opt/proto/data/appMatrix/bin/conduit-server.sh"'

vm-check-pkg-status:
	chmod +x $(SCRIPTS)/vm-check-pkg-status.sh && \
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-check-pkg-status.sh

vm-final-status-report:
	chmod +x $(SCRIPTS)/vm-final-status-report.sh && \
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-final-status-report.sh

# ── Scheduler Tuning for Mobile Devices ────────────────────────────────────────

vm-tune-scheduler:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-tune-scheduler.sh

# ── ZFS Backup & Restore (Phase 1) ────────────────────────────────────────────

vm-backup:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-backup.sh

vm-restore-backup:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-restore-backup.sh

# ── Cage Compositor (kiosk mode, lightweight Wayland) ────────────────────────

vm-setup-cage:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-setup-cage.sh

vm-cage-log:
	@cd $(CURDIR) && . infra/scripts/_agent.sh && agent_exec "tail -20 /tmp/cage.log 2>/dev/null || echo 'Log not available yet'" || true

# ── Full Wayland Pipeline ─────────────────────────────────────────────────────

# Запустить всё: cage headless → wayland-tunnel → bsdos-core → Zenoh
# Mac: make demo-wayland, затем запустить ./mac-companion/metal-viewer/target/release/bsdos-metal-viewer
# demo-wayland: полный Wayland пайплайн. VM должна быть запущена (make vm-x86-start + vm-wait).
# cage (headless) → wayland-tunnel → bsdos-core → Zenoh → metal-viewer (Mac)
demo-wayland:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/demo-wayland.sh

# ── Wayland Tunnel (Wayland wire → WaylandPacket → Zenoh) ────────────────────

debug-wayland-build:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/debug-wayland-build.sh

# bsdos-core-test:start
#   purpose: Run unit tests for the bsdos-core lib (protocol helpers, Cap'n Proto codec).
#            The bridge runtime (zenoh, tokio) is feature-gated and not pulled in
#            during `cargo test --lib --no-default-features`, so the suite runs on
#            stable rust without needing nightly `freeze`.
#
#            The zenoh-peer test fixture (added in v0.1.2) requires the bridge
#            feature and nightly rust. It's tested separately on a VM with
#            nightly toolchain; see bsdos-core-test-with-bridge.
# bsdos-core-test:end

# bsdos-core-test-with-bridge:start
#   purpose: Run the full test suite including the zenoh-peer integration
#            fixture. Requires nightly rust (stabby-abi → core::marker::Freeze).
#            Use this on a FreeBSD VM or Mac with nightly toolchain; do NOT
#            use on host Linux without nightly.
# bsdos-core-test-with-bridge:end

# metal-viewer-test:start
#   purpose: Run unit tests for the cross-platform stream parser + compositor
#            in mac-companion/metal-viewer. The Metal/objc2 stack is target-gated
#            to macOS, so on Linux we build the lib with --no-default-features
#            to skip zenoh (which transitively requires nightly rust).
# metal-viewer-test:end

# unit-tests:start
#   purpose: Run every host-buildable unit-test target in one shot:
#            - bsdos-core lib tests (protocol, capnp)
#            - metal-viewer lib tests (stream_parser, compositor)
#            - wayland-tunnel Zig tests (parse, input framing, stream headers)
#            - sys-daemon-zig sensor conversion tests
# unit-tests:end

stream-reader-run:
	@. $(SCRIPTS)/_agent.sh; agent_exec "timeout 8 /opt/wayland-tunnel/zig-out/bin/stream-reader 2>&1; true" || true

wayland-status:
	@. $(SCRIPTS)/_agent.sh; agent_wayland_status

# tunnel-cleanup:start
#   purpose: Kill stale wayland-tunnel processes before VM start to avoid socket conflicts.
#   input:  none (uses pgrep to find processes by name).
#   output: void (exits 0 regardless of whether processes were found).
#   sideEffects: kills wayland-tunnel processes with SIGKILL; logs to stderr if any were killed.
# tunnel-cleanup:end

# vm-start-cage-foot:start
#   purpose: Start cage compositor with foot terminal (real app, generates frames)
#   input:  none (VM must be running, foot must be installed via vm-setup-phantom.sh or pkg install foot)
#   output: void (exits 0 on success, 1 on failure)
#   sideEffects: stops existing cage, starts cage + foot, waits for wayland-0 socket, chmod 777 socket
vm-start-cage-foot:
	$(SCRIPTS)/vm-start-cage-foot.sh
# vm-start-cage-foot:end

# test-input-e2e:start
#   purpose: End-to-end input test (Mac → Zenoh → bsdos-core → tunnel → foot)
#   input:  none (requires VM + tunnel + bsdos-core + foot running)
#   output: exit 0 on success, 1 on failure
#   sideEffects: publishes synthetic keyboard event to Zenoh, checks foot log
test-input-e2e:
	$(SCRIPTS)/test-input-e2e.sh
# test-input-e2e:end

foot-log:
	@. $(SCRIPTS)/_agent.sh; agent_exec "tail -20 /tmp/foot.log 2>/dev/null; echo '---'; pgrep -la foot 2>/dev/null || echo 'foot not running'" || true

browser-tunnel-log:
	@cd $(CURDIR) && . infra/scripts/_agent.sh && agent_exec "tail -30 /tmp/wayland-tunnel-browser.log 2>/dev/null || echo 'browser tunnel not running'" || true

browser-tunnel-log-full:
	@cd $(CURDIR) && . infra/scripts/_agent.sh && agent_exec "cat /tmp/wayland-tunnel-browser.log 2>/dev/null || echo 'browser tunnel not running'" || true

browser-core-log:
	@cd $(CURDIR) && . infra/scripts/_agent.sh && agent_exec "tail -30 /tmp/core-browser.log 2>/dev/null || echo 'browser core not running'" || true

core-log:
	@cd $(CURDIR) && . infra/scripts/_agent.sh && agent_exec "tail -30 /tmp/core.log 2>/dev/null || echo 'core not running'" || true

core-log-full:
	@cd $(CURDIR) && . infra/scripts/_agent.sh && agent_exec "cat /tmp/core.log 2>/dev/null || echo 'core not running'" || true

vm-mount-wayland-jails:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-mount-wayland-jails.sh

vm-test-wayland-tunnel:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-test-wayland-tunnel.sh

# ── DRM/GPU Diagnostics ────────────────────────────────────────────────────────

check-drm:
	$(SCRIPTS)/check-drm.sh

vm-setup-drm:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-setup-drm.sh

check-rust-version:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/check-rust-version.sh

# ── TLS Certificate Generation for Zenoh ──────────────────────────────────────

gen-tls-certs:
	CERTS_DIR=$(CURDIR)/certs $(SCRIPTS)/gen-tls-certs.sh

vm-deploy-certs:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) \
	    CERTS_DIR=$(CURDIR)/certs \
	    $(SCRIPTS)/vm-deploy-certs.sh

test-core-tls:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/test-core-tls.sh

# ── bsdOS Autostart (rc.d services) ────────────────────────────────────────────

vm-setup-autostart:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-setup-autostart.sh deploy

vm-enable-autostart:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-setup-autostart.sh enable

vm-disable-autostart:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-setup-autostart.sh disable

vm-status-autostart:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/vm-setup-autostart.sh status

vm-pipeline-start:
	ssh -i $(SSH_KEY) freebsd@$(BSDOS_DEV_IP) 'su -m root -c "service bsdos_pipeline start"'

vm-pipeline-stop:
	ssh -i $(SSH_KEY) freebsd@$(BSDOS_DEV_IP) 'su -m root -c "service bsdos_pipeline stop"'

vm-pipeline-restart:
	ssh -i $(SSH_KEY) freebsd@$(BSDOS_DEV_IP) 'su -m root -c "service bsdos_pipeline stop; sleep 1; service bsdos_pipeline start"'

vm-pipeline-status:
	ssh -i $(SSH_KEY) freebsd@$(BSDOS_DEV_IP) 'su -m root -c "service bsdos_pipeline status; tail -5 /tmp/bsdos-core.log"'

vm-pipeline-log:
	ssh -i $(SSH_KEY) freebsd@$(BSDOS_DEV_IP) 'tail -20 /tmp/bsdos-pipeline.log /tmp/wayland-tunnel.log /tmp/bsdos-core.log'

# ── Jail Lifecycle (SIGSTOP cryofreeze) ───────────────────────────────────────
jail-freeze:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/jail-lifecycle.sh freeze $(JAIL)

jail-thaw:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/jail-lifecycle.sh thaw $(JAIL)

jail-lifecycle-status:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/jail-lifecycle.sh status $(JAIL)

# ── .jpk Packaging ────────────────────────────────────────────────────────────
jpk-build:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/jpk.sh build $(SRCDIR) $(OUTFILE)

jpk-install:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/jpk.sh install $(PKGFILE)

jpk-info:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/jpk.sh info $(PKGFILE)

# ── PF Ad-blocking ────────────────────────────────────────────────────────────
pf-adblock-setup:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/pf-adblock.sh setup

pf-adblock-update:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/pf-adblock.sh update

pf-adblock-status:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/pf-adblock.sh status

# ── Beastie Tamagotchi ────────────────────────────────────────────────────────
beastie:
	$(SCRIPTS)/beastie.sh

# ── Phantom Browser ───────────────────────────────────────────────────────────
phantom-setup:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/phantom-browser.sh setup

phantom-start:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/phantom-browser.sh start

phantom-open:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/phantom-browser.sh open $(URL)

phantom-stop:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/phantom-browser.sh stop

phantom-status:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/phantom-browser.sh status

# ── Conduit Matrix ────────────────────────────────────────────────────────────
# ── devfs Rulesets ────────────────────────────────────────────────────────────
devfs-setup:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/devfs-apply.sh setup

devfs-apply:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/devfs-apply.sh apply $(JAIL) $(RULESET)

devfs-status:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/devfs-apply.sh status

# ── ZFS Crypto Profiles ───────────────────────────────────────────────────────
zfs-profile-create:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/zfs-crypto.sh create-profile $(USER)

zfs-profile-load:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/zfs-crypto.sh load-key $(USER)

zfs-profile-unload:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/zfs-crypto.sh unload-key $(USER)

zfs-profile-status:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/zfs-crypto.sh status

zfs-wipe-keys:
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) $(SCRIPTS)/zfs-crypto.sh wipe-keys

# ── Semantic Markup (extracted → github.com/bzdOS/sema) ────────────────────────
sema-check:
	@echo "sema-check moved to github.com/bzdOS/sema"
	@echo "Clone: git clone https://github.com/bzdOS/sema && sema/sema-check.sh ."
	@false

# --- Semantic markup audit (idempotent; safe to re-run) ---
# Adds the module-header + per-function contract stubs to unmarked .rs/.zig files.
# Already-marked files are skipped. Use after sema profile changes to
# pick up newly added files, or to backfill contracts on a new subsystem.
audit-markup:
	$(SCRIPTS)/audit-markup.py

audit-markup-status:
	$(SCRIPTS)/audit-markup.py --status

audit-markup-list:
	$(SCRIPTS)/audit-markup.py --list

# --- Remote dev server ($(BSDOS_HOST_IP)) ---
SERVER_HOST ?= $(BSDOS_HOST_IP)

mac-rsync-docs:
	rsync -av \
	    --filter='- target/' \
	    --filter='- .git/' \
	    --filter='+ */' \
	    --filter='+ *.md' \
	    --filter='- *' \
	    root@$(SERVER_HOST):$(BSDOS_ROOT)/ $(CURDIR)/

mac-build:
	cd $(CURDIR) && cargo build --release -p bsdos-metal-viewer

mac-sync-build: mac-rsync mac-build

# Push a single file: make server-edit FILE=bsdos-core/src/main.rs
server-edit:
	@test -n "$(FILE)" || (echo "Usage: make server-edit FILE=path/relative/to/root" && exit 1)
	rsync -av $(CURDIR)/$(FILE) root@$(SERVER_HOST):$(BSDOS_ROOT)/$(FILE)

# Run viewer with obfs transport (DPI-bypass mode).
# Usage: make mac-viewer-obfs BSDOS_OBFS_PSK=<base64-psk> [SUB=bsdos/jail/appBrowser/stream]
# Push sources to server, then build+restart on the server's FreeBSD VM
server-deploy-core: server-push-core server-build-core

run-core-obfs:
	@test -n "$(BSDOS_OBFS_PSK)" || (echo "Usage: make run-core-obfs BSDOS_OBFS_PSK=<base64-psk>" && exit 1)
	chmod +x $(SCRIPTS)/run-core-obfs.sh && \
	SSH_KEY=$(SSH_KEY) VM_SSH_PORT=$(VM_SSH_PORT) \
	BSDOS_OBFS_PSK=$(BSDOS_OBFS_PSK) \
	ZENOH_LISTEN_IP=$(BSDOS_DEV_IP) ZENOH_LISTEN_PORT=443 \
	    $(SCRIPTS)/run-core-obfs.sh

# ── myvm: Server edition VM, libvirt-managed (see docs/archive/2026-10-01-monorepo/PLAN-myvm.md) ────────────────
# Defined via virt-install --import; disk $(BSDOS_ROOT)/myvm.qcow2; net = bridge br0
# (libvirt creates/owns the vnet tap — we never touch ifconfig/route, HARD RULE).
vm-myvm-start:
	virsh start myvm

vm-myvm-stop:
	virsh shutdown myvm

vm-myvm-status:
	@virsh domstate myvm; virsh domiflist myvm; virsh domifaddr myvm 2>/dev/null || true

# Interactive serial (needs a TTY): virsh console myvm  (escape: Ctrl-])
vm-myvm-console:
	virsh console myvm

# ── F3 Coverage (cargo-llvm-cov) ─────────────────────────────────────────────
# Requires: cargo install cargo-llvm-cov; llvm-cov-18 on PATH (Ubuntu) or llvm-cov (macOS).
# Output: artefacts/coverage/html/ + artefacts/coverage/lcov.info
# Acceptance: ≥60% line coverage on bsdos-core + lifecycled + bsdos-run (F3 DOF).
COVERAGE_DIR     ?= artefacts/coverage
RUST_TOOLCHAIN   ?= nightly-x86_64-unknown-linux-gnu
RUST_LLVM_BIN    ?= $(HOME)/.rustup/toolchains/$(RUST_TOOLCHAIN)/lib/rustlib/x86_64-unknown-linux-gnu/bin
LLVM_COV         ?= $(RUST_LLVM_BIN)/llvm-cov
LLVM_PROFDATA    ?= $(RUST_LLVM_BIN)/llvm-profdata

COVERAGE_IGNORE ?= (main|memory_monitor|zenoh_bridge|mldr|ipa)\.rs|zenoh-link-patched|zenoh-link-commons-patched|bin/sub

# ── F5 Damage Rect CPU Benchmark ─────────────────────────────────────────────
# Runs on the Mac host where metal-viewer is active.
# Usage: make bench-wayland-cpu STREAM_KEY=appTerminal BENCH_DURATION=30
# Acceptance: avg CPU <5% idle (docs/archive/2026-10-01-monorepo/RELEASE-NOTES-v0.1.1.md claim).
STREAM_KEY      ?= appTerminal
BENCH_DURATION  ?= 30
BENCH_THRESHOLD ?= 5

bench-wayland-cpu:
	STREAM_KEY=$(STREAM_KEY) BENCH_DURATION=$(BENCH_DURATION) \
	BENCH_CPU_THRESHOLD=$(BENCH_THRESHOLD) \
	    $(SCRIPTS)/bench-wayland-cpu.sh
