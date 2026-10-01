# bzdOS — documentation index

> **2026-10-01: the bsdOS monorepo is dissolved.** This repository is the
> distribution (image build, base services, jailed apps), its dev loop (dev VM,
> guest agent, deploy) and the team process. Other components live in their own
> `github.com/bzdOS` repos. Host values (IPs, keys, data dir) are not in git:
> `/etc/bsdos/hosts.env`. Where each component went: [docs/EXTRACTION-MAP.md](docs/EXTRACTION-MAP.md).

## Where component docs live now

| Repo | What its docs cover |
|---|---|
| [bzdOS](https://github.com/bzdOS/bzdOS) | the distribution: image build, base services, jailed-app model, `docs/specs/` (Squirrel rootfs, 2-stream, .jpk, Chimp release/security/networking/zenoh, net v1, Zenoh keyspace/security), BPI-M64 boot chain, bsdos-core ↔ WLTunnel deploy contract |
| [hal/](hal/) | HAL daemon, GPU backend; `docs/SPEC_chimp_hal.md` (EL2 owns the hardware) (was the bsdos-hal repo, merged 2026-10-01) |
| [bzdk](https://github.com/bzdOS/bzdk) | the EL2 hypervisor on BPI-M64 |
| [lima-freebsd](https://github.com/bzdOS/lima-freebsd) | Mali-400 DRM driver |
| [WLTunnel](https://github.com/bzdOS/WLTunnel), [WLStream](https://github.com/bzdOS/WLStream), [metal-viewer](https://github.com/bzdOS/metal-viewer) | Wayland streaming: tunnel, wire format, macOS viewer |
| [zenoh-freebsd](https://github.com/bzdOS/zenoh-freebsd) | FreeBSD-patched Zenoh, obfs link |
| [ipa-runtime](https://github.com/bzdOS/ipa-runtime), [darling](https://github.com/bzdOS/darling) | iOS/macOS binaries on FreeBSD |
| [mrgd](https://github.com/bzdOS/mrgd), [hubd](https://github.com/bzdOS/hubd) | Matrix homeserver / coordination bus; the agent tracker |
| [SeMa](https://github.com/bzdOS/SeMa) | semantic markup methodology and validator |

Repos prepared under `/srv/split/` and not pushed yet: hubd task `a hub task`.

## Team process (read first)

- [CLAUDE.md](CLAUDE.md) — hard rules and the operating model.
- [AGENTS.md](AGENTS.md) — roles, claims, queues; reads [SESSION_RULES.md](SESSION_RULES.md) and [INBOX.md](INBOX.md).
- [DESIGN-agent-driven-stack.md](DESIGN-agent-driven-stack.md) — why FreeBSD + Zig + Zenoh + Cap'n Proto.
- [ROADMAP.md](ROADMAP.md) — ⚠ last real update 2026-06-26; live status is the hubd backlog (project `bsdos`).

## Host operations

| Doc | What |
|---|---|
| [docs/ops/DEV-VM.md](docs/ops/DEV-VM.md) | the build VM `bsdos-x86` (dev-vm): access, virtiofs/9p, recovery |
| [infra/vm-templates/README-x86-kvm.md](infra/vm-templates/README-x86-kvm.md) | libvirt domain layout for the dev VM |
| [docs/ops/RUNBOOK-myvm-virtio-serial.md](docs/ops/RUNBOOK-myvm-virtio-serial.md) | virtio-serial agent channel on myvm (myvm) |
| [docs/agent-proto-v2.md](docs/agent-proto-v2.md) | guest agent protocol v2 (`guest-agent/`) |
| [docs/ops/certs.md](docs/ops/certs.md) | Zenoh TLS configs (the certs themselves: `/etc/bsdos/certs`) |

## Plans in flight

- [docs/ops/PLAN-host-split.md](docs/ops/PLAN-host-split.md) — moving the repo's roles (VM disks, shared FS, prod units, source) off buildhost.
- [docs/EXTRACTION-MAP.md](docs/EXTRACTION-MAP.md) — the component split and its follow-ups.

## Not yet started

- `docs/woodpecker/SPEC_woodpecker_*.md` — Woodpecker v0.3 (oBzdOS, PinePhone on OpenBSD): apps, HAL, mobile, power, thermal, vision. No repository yet.

## Archive

The monorepo's archived plans, designs and release notes are in the local attic
(no remote). What they still teach: [docs/LESSONS.md](docs/LESSONS.md).

Elsewhere: mesh and matrix-hs deploy — `bzdOS/mrgd: deploy/bsdos/`; hubd → Matrix
bridge — `bzdOS/hubd: contrib/bsdos/`; zenohd — `bzdOS/zenoh-freebsd: zenohd/`.
