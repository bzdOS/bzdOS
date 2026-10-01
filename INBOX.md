# INBOX — журнал команды bsdOS (append-only, новые записи СВЕРХУ)
*Формат и ритуал — AGENTS.md, раздел «Координация команды разработки».*

## 2026-06-15 20:30 · claude-host (architect, multi-arch-pivot)
Тема: Squirrel reframed to multi-arch (amd64 + aarch64). Статус: ✅ patched.

**User directive 2026-06-15 ("арм и амд равнозначный пока"):** Squirrel = multi-arch.
amd64 QEMU = primary dev loop (KVM fast). aarch64 QEMU = architectural target
(Chimp/Woodpecker-ready). Both ship in same release, both tested in CI.

**Коррекция моей ошибки:** ранее я framed "amd64 QEMU is historical accident,
aarch64 is architecturally canonical". Это privilege aarch64 на основании
codename progression, но architecturally для QEMU sandbox обе arch равнозначны.
User correction → multi-arch.

**Patched docs:**
- docs/specs/SPEC_squirrel_rootfs.md: v1 → v2. Title/§1/§2/§4/§5/§6/§7/§8/§9/§10/§11/§12/§13
  updated. Output = 2 images per release. Build script takes $ARCH. Makefile has
  per-arch targets. CI tests both. Open question #7 added: "Architecture:
  amd64 or aarch64?" → BOTH. 6 default decisions (kernel config per arch,
  wpewebkit-fdo, pmap_zstd, no signing yet, autostart, cage).
- docs/specs/SPEC_2stream_squirrel.md: v1 → v2. Architecture-agnostic note
  added to §1. "Zenoh pub/sub, per-app_id topics, and Mac client work the
  same on both archs."
- ROADMAP.md: Phase 0.2 Squirrel section rewritten. Was "amd64 was historical"
  → "v0.1.3 Squirrel = multi-arch". Title/§1/§2 updated.
- CLAUDE.md: Platform row + Animal codenames table + Cross-cutting note
  updated. Removed "amd64 is HISTORICAL", added "Squirrel multi-arch (locked
  2026-06-15)".
- AGENTS.md: Animal codename note updated. Squirrel row now says "amd64 +
  aarch64, multi-arch per user".
- SESSION_RULES.md: §3 Animal codename scheme table updated. §1 obligatory
  reading already correct (no change needed).

**Net effect:** Squirrel build pipeline produces 2 images (amd64 + aarch64).
Acceptance test runs on both. CI fails if either breaks. Implementation
parallel (one Makefile target per arch, one smoke per arch). No code changes
needed in bsdos-core/bsdos-hal/bsdos_lifecycled — they already cross-compile.

**Lesson:** Architecture is a deployment matrix, not a progress narrative.
Multi-arch Squirrel = correct from start. Privilege based on codename
progression is wrong framing for QEMU sandbox stage.
