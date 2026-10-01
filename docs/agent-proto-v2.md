# bsdOS agent — protocol v2 (job lifecycle + no-silent-fail)

> **STATUS 2026-07-07: DEPLOYED + VERIFIED on dev-vm.** Guest `bsdos-agent` **v0.4.1**
> built natively on the guest + live (`HELLO` → `proto=2`); host `agent-run.sh` is
> proto-aware (auto-detect, cap 3900, `JOB_STATUS` completion, v1 `__RC__` fallback).
> Original bug fixed: a 699-char `run` that hung ~600s now returns in 0s; exit codes
> propagate (7/0/1 verified via `JOB_STATUS rc`); `JOB_STATUS/JOB_LIST/JOB_KILL/JOB_GC`
> all working. **Gotcha:** rc.d `_bin` = `/opt/bsdos/bin/bsdos-agent` (NOT
> `/usr/local/bin` — `build-agent.sh`'s path; installing there had no effect on the
> first deploy). Rollback binary: `/opt/bsdos/bin/bsdos-agent.bak` (v0.4.0).

Design contract for the vport agent refactor (2026-07-07). **Backward-compatible:**
every v1 verb keeps its behaviour; v2 only *adds* verbs and *enlarges* buffers.
A v2 guest MUST serve a v1 host unchanged; a v2 host MUST detect proto and fall
back to v1 behaviour against a v1 guest. This lets us land host-script changes on
the shared tree BEFORE the guest binary is redeployed.

## Root cause being fixed
`job_run()` formatted `<cmd> >/tmp/bsdos-job-<id>.log 2>&1` into a fixed `[512]u8`
buffer and did `bufPrint(...) catch return` — on overflow the job was SILENTLY
dropped (no spawn, no log). `JOB_LOG` then ran `tail -100 <missing-file>` → exit 1
→ reply `-ERR 1`, and the host poll loop (which only completes on a `__RC__:` marker
scraped from the log) span the full ~600 s. Completion was in-band + fragile.

## Wire protocol (unchanged in v2)
`CMD [ARG…]\r\n` → response lines → terminator line `.` (`\n`).
First response line: `+OK [msg]` or `-ERR [msg]`. (The lone-`.` framing flaw —
output containing a bare `.` line truncates the response — is a KNOWN v1 limitation;
a length-framed v3 is deferred, it needs a simultaneous both-sides cutover and is
too risky on the live shared channel. Do NOT change framing in this pass.)

## GUEST changes (`guest-agent/src/main.zig`) — Agent G

1. **No silent buffer failures.** `job_run` wrapper buffer 512 → **4096**, and on
   `bufPrint` overflow return an error the caller turns into `-ERR cmd-too-long`
   (NOT `catch return`). Audit every fixed buffer in dispatch/job paths (`resp`,
   the input line buffer, `msg[64]`, `path[64]`): on overflow reply `-ERR …`, never
   silently truncate/drop.
2. **Job table** — a fixed array (cap 32). Per job: `id`, `pid`, `state`
   (`running|exited|killed|none`), `rc`, `started` (unix ts via `std.time.timestamp()`).
   `JOB_RUN` registers a slot with the child pid; reuse/evict `none`/reaped slots.
   If the table is full reply `-ERR job-table-full`.
3. **Reaping** — a `reap()` that `waitpid(pid, WNOHANG)`s every `running` job and
   records `state=exited, rc=<code>` (or `killed`). Call it at the top of
   `JOB_STATUS`, `JOB_LIST`, `JOB_GC`.
4. **New verbs (additive):**
   - `HELLO` → `+OK bsdos-agent proto=2 jobs=<used>/<cap>`  (version handshake)
   - `JOB_STATUS <id>` → `+OK state=running` | `+OK state=exited rc=<n>` |
     `+OK state=killed` | `-ERR no-such-job`  ← **out-of-band rc, replaces __RC__**
   - `JOB_LIST` → `+OK` then one line per live slot: `<id> <state> <rc> <age>s`
   - `JOB_KILL <id>` → SIGTERM the pid (then it reaps to `killed`); `+OK` | `-ERR no-such-job`
   - `JOB_GC [age_s=3600]` → reap, then rm `/tmp/bsdos-job-<id>.log` + free slots for
     jobs exited longer than age_s ago; `+OK gc=<count>`
5. **Keep** `JOB_RUN`/`JOB_LOG` exactly as-is on the happy path (still `>log 2>&1`,
   still `tail -100`, still `+OK log=…`). The host still appends `echo __RC__:$?`
   for v1 fallback; that's fine — v2 ignores it and uses `JOB_STATUS`.
6. Do NOT touch unrelated verbs (EXEC/JLS/FREEZE/MEM_*/WAYLAND_*…). Build must stay
   `zig build -Doptimize=ReleaseFast`; target is x86_64-freebsd. Keep it compiling.

## HOST changes (`infra/scripts/_agent.sh`, `agent-run.sh`) — Agent H
Work in the provided git worktree; do NOT edit the live tree. Changes must keep the
script valid (`sh -n`) and backward-compatible with a v1 guest.

1. `_agent.sh`: add `agent_proto()` — sends `HELLO`, parses `proto=N`, caches the
   result in a file (e.g. `/tmp/bsdos-agent-proto`, 60 s TTL); a `-ERR`/no-HELLO
   guest ⇒ proto=1. Optional: use this cache to skip the per-call `PING` in
   `_agent_transport()` when a recent success is cached (still fail-loud, still no
   ssh — do not weaken the AGENT_ALLOW_SSH gate).
2. `agent-run.sh run`: KEEP the Ф0 length guard (raise `RUN_MAX_CMD` default to 3900
   to match the 4096 guest buffer). After submit:
   - if proto>=2: poll `JOB_STATUS <id>` (sleep between polls, releasing flock). On
     `state=exited rc=N` → one `JOB_LOG <id>` for output, print it (strip the `+OK`
     header + any trailing `__RC__:` line), then `JOB_GC`-or-`rm` this id, `exit N`.
     On `-ERR no-such-job` for >=RUN_MISS_MAX polls → abort (job dropped).
   - if proto<2: current __RC__-scraping behaviour (unchanged).
3. Preserve exit codes, the submit `-ERR` fast-fail, and the empty=contention rule
   from Ф0. Add a short comment block explaining proto detection.

## Integration / deploy (owner: orchestrator, NOT the agents)
Cross-compile here (`zig build -Dtarget=x86_64-freebsd -Doptimize=ReleaseFast`),
scp the binary, `service bsdos_agent restart` via vport (coordinated, rollback the
old binary kept as `.bak`). Verify `HELLO`, a short `run`, a >512-char `run`
(now succeeds), and `JOB_STATUS`/`JOB_LIST` before declaring done.
