# Design draft: DEVFS_MOUNT verb for nested-jail devfs ruleset 4

Status: **design + prototype only, not deployed, not live-tested.** Written as
the design pass the originating task (jailrun-side ROADMAP gap, tracked
cross-project) explicitly asked for before implementing anything. Lives on
branch `devfs-ruleset4-design` in an isolated worktree — not merged, not
pushed, not touching any running daemon.

## The problem

When jailrun runs nested (inside another application's production jail) and
creates its own child "run-jail", it needs to give that run-jail a `/dev`
with the restricted devfs ruleset (ruleset 4 — `null`, `zero`, `random`,
etc., but not raw memory/disk devices). Applying a devfs ruleset requires
`PRIV_DEVFS_RULE`, a **host-only** privilege — not something any `allow.*`
jail(8) parameter can delegate down into a jail. A process running inside a
jail can only ever mount a *fresh* devfs at ruleset 0 (unrestricted) for its
own children.

Confirmed live (2026-07-23, jailrun-side): a process inside such a nested,
ruleset-0 run-jail can successfully `dd if=/dev/mem` — a genuine physical
host-memory-disclosure primitive, reachable by whatever untrusted code the
sandbox exists to contain. jailrun's `engine.run()` now fails closed on this
by default (`RuntimeError`, opt-in `--allow-unrestricted-devfs` escape hatch
for trusted/manual testing only).

A nullfs-bind of an *already-restricted* host devfs into the nested jail was
tried and does not work either — clonable devices (`/dev/null`, `/dev/zero`,
`/dev/urandom`) don't function correctly through a nullfs bind of devfs.

## The fix this designs

`bsdos_lifecycled` runs on the bare host, outside every jail — it has
`PRIV_DEVFS_RULE` unconditionally. jailrun already talks to it over its
existing AF_UNIX socket (see `jailrun/runtime/lifecycle.py`) for jail
teardown. This adds one more verb: the nested jailrun asks the host daemon to
do the one privileged mount on its behalf.

### Wire protocol addition

```
DEVFS_MOUNT <jail_id>
```

Response (matches the daemon's real, existing plain-text format — see
"Correction" below): `+OK devfs ruleset=4 mounted at <path>/dev for
jail=<jail_id>\n` or `-ERR <message>\n`.

**No path argument.** This is the central security decision, not an
oversight:

1. The caller supplies only a `jail_id` (a name string, validated the same
   way every other verb here already validates one via `validate_jail_id`).
2. The daemon resolves that name to its **kernel-reported** filesystem root
   via a new `jail_enum::path_by_name()` — a direct `jail_get(2)` call
   requesting the `"path"` parameter, mirroring the existing `jid_by_name()`
   FFI pattern exactly. The path never comes from the caller.
3. The mount target is always `<kernel-resolved path>/dev` — a **fixed**
   subpath, not a caller-supplied one.

A compromised or buggy caller therefore cannot smuggle an arbitrary host
path into a privileged `mount -t devfs -o ruleset=4` call — the only thing
it controls is *which jail_id* to ask about, and the kernel is the sole
source of truth for that jail's real path. This is deliberately narrower
than a general "mount X at Y" verb: the only real use case is "give this one
specific run-jail's `/dev` a restricted devfs", so the protocol shouldn't
accept more authority than that single operation needs.

### What's implemented (prototype, this branch)

- `lifecycled/src/jail_enum.rs`: `path_by_name(name) -> Result<String, String>`
  (FreeBSD: real `jail_get(2)` FFI; non-FreeBSD: stub `Err`), added to the
  public re-export and to the existing `stubs_degrade_safely_off_freebsd`
  test.
- `lifecycled/src/main.rs`: `mount_devfs_ruleset4(jail_id) -> Result<String, String>`,
  wired into `dispatch_cmd` as `DEVFS_MOUNT <jail_id>`, `HELP` text updated.
- Verified: `cargo check --target aarch64-unknown-freebsd` compiles clean
  (only pre-existing warnings, nothing new); `cargo check` (Linux stub path)
  compiles clean; `cargo test --bin bsdos-lifecycled jail_enum` — 3/3 pass,
  including the extended stub-degradation test.
- **Not implemented / not verified**: nothing was run against a real nested
  jail. The `mount` invocation itself, its exact error text on an
  already-mounted target, and whether the resulting devfs actually behaves
  correctly for a jailrun run-jail are all unverified.

### Open questions — need live verification before this ships

1. **Idempotency.** What does `mount -t devfs -o ruleset=4 devfs <path>`
   actually do on FreeBSD when a devfs is *already* mounted at that exact
   path — clean failure, a second stacked mount, or a silent no-op? This
   draft's `mount_devfs_ruleset4` treats an "already mounted"-shaped error
   string as success, which is an **unverified guess** at FreeBSD's actual
   behavior, not a confirmed one. Needs a real nested jail to observe.
2. **Teardown symmetry.** There is no `DEVFS_UNMOUNT` verb yet. Whether/when
   to unmount this devfs relative to `jail -r` and the rest of
   `store.destroy()`'s teardown sequence (see jailrun's `store/store.py`,
   which already does careful deepest-first unmount ordering for its own
   nullfs binds) needs its own symmetric design pass.
3. **Integration shape on the jailrun side.** Does jailrun's jail.conf stop
   emitting `mount.devfs;` for the nested case entirely (relying on this
   pre-mounted `/dev` already being there when `jail -c` runs), or is there a
   cleaner integration point? This is a `runtime/engine.py`
   (`_build_jail_conf`) question that needs to be worked out *with* a real
   nested jail to observe actual `jail -c` behavior against a pre-existing
   `/dev`, not guessed at from the daemon side alone.
4. **Path-translation edge cases.** `jail_get(2)`'s "path" parameter reports
   the jail's root *as the kernel sees it* — need to confirm this resolves
   correctly for a jail nested two levels deep (host → outer application jail
   → jailrun's own run-jail) the way this design assumes, rather than, say,
   only being resolvable from the outer jail's own vantage point.

### A separate bug this design pass surfaced (not part of this feature)

Reading `jailrun/runtime/lifecycle.py`'s docstring against the daemon's
*actual* `handle_conn`/`dispatch_cmd` code: the docstring claims the daemon
returns JSON (`{"cmd":..,"ok":bool,...}`), but the real wire format is plain
text — `+OK <msg>\n` / `-ERR <msg>\n` (see `handle_conn`, `main.rs:401`).
`Lifecycled._cmd()` does `json.loads(raw)` and falls back to
`{"ok": True, "raw": raw}` on a `JSONDecodeError` — since the real responses
are never valid JSON, **every call currently falls into that fallback and
reports `ok: True` unconditionally**, even when the daemon actually replied
`-ERR ...`. jailrun's lifecycle client can never currently detect a real
daemon-side failure. Worth a fix on its own, independent of this devfs work
— the client should check for a `+OK`/`-ERR` prefix directly rather than
attempting `json.loads` against a protocol that was never JSON.
