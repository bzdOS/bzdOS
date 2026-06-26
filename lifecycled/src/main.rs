// START_AI_HEADER
// MODULE: lifecycled/src/main.rs
// PURPOSE: bsdOS Lifecycle Daemon — manages jail lifecycle (FREEZE/THAW/HIBERNATE/RESTORE/KILL)
//          over Unix socket + Zenoh bsdos/ctl/lifecycle topic.
// INTENT: Provide per-jail process lifecycle management with ZFS snapshot-based hibernation,
//         memory-pressure-driven eviction, and Zenoh control-plane integration.
// DEPENDENCIES: tokio, std::collections::HashMap, std::sync::{Arc, Mutex, AtomicBool}, libc,
//               tokio::process::Command, zenoh, serde_json
// PUBLIC_API: freeze_application(), thaw_application(), hibernate_application(),
//             kill_application(), MEM_GUARD_DISABLED
// END_AI_HEADER

mod memory_monitor;
mod zstd_pool;
mod jpk_config;
mod zenoh_bridge;
mod policy;
mod jail_enum;
use jail_enum::Sig;
use memory_monitor::{PriorityMap, JailPriority, read_mem_stats, setup_zfs_swap};
use jpk_config::{load_descriptors, default_zpids_path, default_jpk_dir};
use policy::{LifecyclePolicy, platform_name};
use std::sync::atomic::{AtomicBool, Ordering};

// Global memory guard flag: when true, memory monitor skips jail kills
pub static MEM_GUARD_DISABLED: AtomicBool = AtomicBool::new(false);

// bsdOS Lifecycle Daemon — управляет жизненным циклом jail-приложений.
//
// Три сценария:
//   FREEZE  <jail_id> — SIGSTOP всем процессам jail → 0% CPU, состояние в RAM
//   THAW    <jail_id> — SIGCONT → мгновенный возврат (<1ms)
//   HIBERNATE <jail_id> — ZFS snapshot state + SIGSTOP (без RAM swap — ограничение FreeBSD)
//   RESTORE <jail_id> — thaw из hibernate (если не выгружен) или восстановить из snapshot
//   KILL    <jail_id> — SIGKILL + cleanup Wayland-сокета и /tmp внутри jail
//   STATUS  <jail_id> — текущее состояние
//
// Протокол: Unix-сокет /var/run/bsdos-lifecycle.sock
// Запросы:  CMD <jail_id>\n
// Ответы:   +OK ...\n  /  -ERR ...\n
//
// Реалистичная гибернация на FreeBSD:
//   FreeBSD userspace не имеет аналога Linux MADV_PAGEOUT (нет CRIU, нет /proc/pid/mem write).
//   Реализуем «контекстную гибернацию»: freeze процессов + ZFS snapshot всей jail ФС.
//   При нехватке RAM: kill процессов, данные живут в ZFS snapshot.
//   Restore: zfs rollback + перезапуск entry point (как Android Activity restart).
//   Для настоящего RAM-swap нужен FreeBSD kernel patch (вне scope userspace).

use std::collections::HashMap;
use std::os::unix::fs::PermissionsExt;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::process::Command;

// ── Состояние приложений ─────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq)]
pub enum AppState {
    Running,
    Frozen,              // SIGSTOP — в RAM, 0% CPU
    Hibernated,          // SIGSTOP + ZFS snapshot — может быть выгружен из RAM
    Dead,
}

pub type StateMap = Arc<Mutex<HashMap<String, AppState>>>;

// ── Утилиты ──────────────────────────────────────────────────────────────────

/// Async выполнение команды — не блокирует tokio runtime.
/// tokio::process::Command: spawn + await, I/O идёт через OS async.
// run:start
//   purpose: Execute a command with args asynchronously via tokio and return stdout or error.
//   input:  program — executable path; args — command arguments
//   output: Result<String, String> (stdout on success, error on failure)
//   sideEffects: spawns a child process asynchronously
async fn run(program: &str, args: &[&str]) -> Result<String, String> {
    let out = Command::new(program)
        .args(args)
        .output()
        .await
        .map_err(|e| format!("exec {program}: {e}"))?;

    let stdout = String::from_utf8_lossy(&out.stdout).to_string();
    let stderr = String::from_utf8_lossy(&out.stderr).to_string();

    if out.status.success() { Ok(stdout) }
    else { Err(format!("exit {}: {}", out.status, stderr.trim())) }
}
// run:end

/// Валидация jail_id: только a-z, 0-9, дефис/подчёркивание
// validate_jail_id:start
//   purpose: Validate jail_id format — alphanumeric, dash, underscore, 1-64 chars.
//   input:  id — jail identifier string
//   output: Result<&str, String> (same id on success, error description on failure)
//   sideEffects: none
fn validate_jail_id(id: &str) -> Result<&str, String> {
    if id.is_empty() || id.len() > 64 {
        return Err("invalid jail_id length".to_string());
    }
    for ch in id.chars() {
        if !matches!(ch, 'a'..='z' | 'A'..='Z' | '0'..='9' | '-' | '_') {
            return Err(format!("invalid char in jail_id: {ch}"));
        }
    }
    Ok(id)
}
// validate_jail_id:end

// ── FreeBSD syscall bindings ──────────────────────────────────────────────────
//
// Real jail enumeration lives in `jail_enum` (jail_get(2) lastjid-iteration +
// sysctl(KERN_PROC_PROC) filtered by kinfo_proc.ki_jid). signal_jail here is a
// thin adapter: it maps the textual signal name to a Sig and signals every REAL
// PID of the jail — not kill(-jid), which was wrong (a JID is not a PGID on
// FreeBSD).

/// Отправить сигнал всем РЕАЛЬНЫМ процессам jail (по PID).
// signal_jail:start
//   purpose: Send a signal to every real PID of a jail — resolve name→jid via
//            jail_get(2), enumerate PIDs via sysctl(KERN_PROC_PROC) filtered by
//            ki_jid, then kill(pid, sig) each. NOT kill(-jid) (JID is not a PGID).
//   input:  jail_id — jail name; signal — signal name string ("SIGSTOP"/"-STOP",
//           "SIGCONT"/"-CONT", "SIGKILL"/"-KILL", "-0" probe)
//   output: Result<usize, String> (number of PIDs the signal was delivered to)
//   sideEffects: calls jail_get(2), sysctl(2), kill(2) per PID (FreeBSD); Err off FreeBSD
fn signal_jail(jail_id: &str, signal: &str) -> Result<usize, String> {
    let sig = match signal {
        "-STOP" | "SIGSTOP" => Sig::Stop,
        "-CONT" | "SIGCONT" => Sig::Cont,
        "-KILL" | "SIGKILL" => Sig::Kill,
        "-0"                => Sig::Probe,
        other => return Err(format!("unknown signal: {other}")),
    };

    let n = jail_enum::signal_jail_pids(jail_id, sig)?;
    eprintln!("[signal_jail] {jail_id}: sig={signal} delivered to {n} pids");
    Ok(n)
}
// signal_jail:end

// ── Сценарий 1: Криозаморозка ────────────────────────────────────────────────

/// SIGSTOP всем процессам → 0% CPU, полное состояние в RAM.
/// Возврат мгновенный (SIGCONT), без потери UI-состояния.
// freeze_application:start
//   purpose: Freeze a jail by sending SIGSTOP to all its processes (0% CPU, state in RAM).
//   input:  jail_id — jail name; states — shared StateMap reference
//   output: Result<String, String> (success message or error)
//   sideEffects: sends SIGSTOP via signal_jail, updates state map
pub async fn freeze_application(jail_id: &str, states: &StateMap) -> Result<String, String> {
    let jail_id = validate_jail_id(jail_id)?;
    eprintln!("[lifecycle] freezing {jail_id}");

    let n = signal_jail(jail_id, "-STOP")?;
    states.lock().unwrap_or_else(|p| p.into_inner()).insert(jail_id.to_string(), AppState::Frozen);
    eprintln!("[lifecycle] {jail_id}: {n} processes frozen");
    Ok(format!("frozen jail={jail_id} procs={n}"))
}
// freeze_application:end

/// SIGCONT → мгновенный возврат (<1ms, без перезапуска).
// thaw_application:start
//   purpose: Thaw a frozen jail by sending SIGCONT to all its processes (instant resume).
//   input:  jail_id — jail name; states — shared StateMap reference
//   output: Result<String, String> (success message or error)
//   sideEffects: sends SIGCONT via signal_jail, updates state map
pub async fn thaw_application(jail_id: &str, states: &StateMap) -> Result<String, String> {
    let jail_id = validate_jail_id(jail_id)?;
    eprintln!("[lifecycle] thawing {jail_id}");

    let n = signal_jail(jail_id, "-CONT")?;
    states.lock().unwrap_or_else(|p| p.into_inner()).insert(jail_id.to_string(), AppState::Running);
    eprintln!("[lifecycle] {jail_id}: {n} processes resumed");
    Ok(format!("thawed jail={jail_id} procs={n}"))
}
// thaw_application:end

// ── Сценарий 2: Гибернация в ZFS ─────────────────────────────────────────────

/// «Контекстная гибернация»:
///   1. Freeze (SIGSTOP) — всё застывает
///   2. ZFS snapshot jail ФС → состояние данных сохранено
///   3. При нехватке RAM: kill процессов, данные живут в snapshot
///
/// ЧЕСТНОЕ ОГРАНИЧЕНИЕ: FreeBSD userspace не имеет аналога Linux MADV_PAGEOUT.
/// RAM страницы не сериализуются — сохраняется только файловое состояние.
/// Полный RAM-checkpoint требует ядерного патча (CRIU-FreeBSD, вне scope).
// hibernate_application:start
//   purpose: Hibernate a jail: freeze processes + take a ZFS snapshot of the dataset.
//   input:  jail_id — jail name; states — shared StateMap reference
//   output: Result<String, String> (success message with snapshot name, or error)
//   sideEffects: sends SIGSTOP, spawns zfs snapshot, updates state map
pub async fn hibernate_application(jail_id: &str, states: &StateMap) -> Result<String, String> {
    let jail_id = validate_jail_id(jail_id)?;
    eprintln!("[lifecycle] hibernating {jail_id}");

    // Шаг 1: заморозить процессы
    signal_jail(jail_id, "-STOP").unwrap_or_default();

    // Шаг 2: ZFS snapshot jail датасета
    // Предполагаем датасет: bsdos/apps/<jail_id>
    let dataset = format!("bsdos/apps/{jail_id}");
    let snapshot = format!("{dataset}@hibernate-{}", unix_timestamp());
    eprintln!("[lifecycle] {jail_id}: snapshot → {snapshot}");

    run("zfs", &["snapshot", &snapshot]).await
        .map_err(|e| format!("zfs snapshot failed: {e}"))?;

    states.lock().unwrap_or_else(|p| p.into_inner()).insert(jail_id.to_string(), AppState::Hibernated);
    eprintln!("[lifecycle] {jail_id}: hibernated snapshot={snapshot}");
    Ok(format!("hibernated jail={jail_id} snapshot={snapshot}"))
}
// hibernate_application:end

/// Выход из гибернации:
///   - Если процессы ещё в RAM (frozen): просто SIGCONT
///   - Если убиты: zfs rollback + сигнал перезапуска entry-point
// restore_application:start
//   purpose: Restore a jail: thaw if processes still in RAM, otherwise ZFS rollback + restart.
//   input:  jail_id — jail name; states — shared StateMap reference
//   output: Result<String, String> (success message or error)
//   sideEffects: sends SIGCONT, may spawn zfs rollback, updates state map
async fn restore_application(jail_id: &str, states: &StateMap) -> Result<String, String> {
    let jail_id = validate_jail_id(jail_id)?;
    eprintln!("[lifecycle] restoring {jail_id}");

    let state = states.lock().unwrap_or_else(|p| p.into_inner()).get(jail_id).cloned().unwrap_or(AppState::Dead);
    match state {
        AppState::Frozen | AppState::Hibernated => {
            // Попробовать SIGCONT — если процессы живы, этого достаточно
            match signal_jail(jail_id, "-CONT") {
                Ok(n) if n > 0 => {
                    states.lock().unwrap_or_else(|p| p.into_inner()).insert(jail_id.to_string(), AppState::Running);
                    Ok(format!("restored jail={jail_id} procs={n} method=thaw"))
                }
                _ => {
                    // Процессов нет — нужен zfs rollback + перезапуск
                    eprintln!("[lifecycle] {jail_id}: no procs, zfs rollback needed");
                    rollback_and_restart(jail_id, states).await
                }
            }
        }
        other => Err(format!("cannot restore from state: {other:?}")),
    }
}
// restore_application:end

// rollback_and_restart:start
//   purpose: Find the latest hibernate snapshot for a jail, ZFS rollback, and mark state as Running.
//   input:  jail_id — jail name; states — shared StateMap reference
//   output: Result<String, String> (success message or error)
//   sideEffects: spawns zfs list and zfs rollback, updates state map
async fn rollback_and_restart(jail_id: &str, states: &StateMap) -> Result<String, String> {
    let dataset = format!("bsdos/apps/{jail_id}");

    // Найти последний hibernate snapshot
    let snaps = run("zfs", &["list", "-t", "snapshot", "-o", "name", "-H", &dataset]).await?;
    let latest = snaps.lines()
        .filter(|l| l.contains("@hibernate-"))
        .last()
        .ok_or("no hibernate snapshot found")?
        .trim()
        .to_string();

    eprintln!("[lifecycle] {jail_id}: rolling back to {latest}");
    run("zfs", &["rollback", &latest]).await?;

    // TODO: перезапустить entry-point через jexec(8) — читать /etc/rc.local внутри jail и выполнить
    // Пока сигнализируем что jail готов к рестарту
    states.lock().unwrap_or_else(|p| p.into_inner()).insert(jail_id.to_string(), AppState::Running);
    Ok(format!("restored jail={jail_id} snapshot={latest} method=rollback"))
}
// rollback_and_restart:end

// ── Сценарий 3: Хирургический SIGKILL ────────────────────────────────────────

/// SIGKILL + очистка Wayland-сокета и /tmp внутри jail.
/// Ноль мусора: ZFS прячет clean state за snapshot, /tmp очищается.
// kill_application:start
//   purpose: Kill a jail: SIGKILL all processes, remove Wayland socket, recycle /tmp ZFS dataset.
//   input:  jail_id — jail name; states — shared StateMap reference
//   output: Result<String, String> (success message or error)
//   sideEffects: sends SIGKILL, removes file, spawns zfs destroy and zfs create, updates state map
pub async fn kill_application(jail_id: &str, states: &StateMap) -> Result<String, String> {
    let jail_id = validate_jail_id(jail_id)?;
    eprintln!("[lifecycle] killing {jail_id}");

    // Шаг 1: SIGKILL всем процессам
    let n = signal_jail(jail_id, "-KILL").unwrap_or(0);
    eprintln!("[lifecycle] {jail_id}: SIGKILL sent to {n} procs");

    // Шаг 2: Очистка Wayland-сокета
    let wayland_sock = format!("/jails/apps/{jail_id}/tmp/wayland-0");
    if std::path::Path::new(&wayland_sock).exists() {
        if let Err(e) = std::fs::remove_file(&wayland_sock) {
            eprintln!("[lifecycle] {jail_id}: wayland cleanup warn: {e}");
        } else {
            eprintln!("[lifecycle] {jail_id}: wayland socket removed");
        }
    }

    // Шаг 3: Очистка /tmp внутри jail через ZFS
    // Если есть датасет bsdos/apps/<id>/tmp — уничтожаем и пересоздаём
    let tmp_dataset = format!("bsdos/apps/{jail_id}/tmp");
    let has_tmp_dataset = run("zfs", &["list", &tmp_dataset]).await.is_ok();
    if has_tmp_dataset {
        let _ = run("zfs", &["destroy", "-f", &tmp_dataset]).await;
        let _ = run("zfs", &["create", &tmp_dataset]).await;
        eprintln!("[lifecycle] {jail_id}: /tmp dataset recycled");
    }

    states.lock().unwrap_or_else(|p| p.into_inner()).insert(jail_id.to_string(), AppState::Dead);
    Ok(format!("killed jail={jail_id} procs={n} cleanup=done"))
}
// kill_application:end

// ── Статус ───────────────────────────────────────────────────────────────────

/// Real {jid, state, pids} snapshot of one jail.
/// jid<0 / empty pids mean the jail is not currently live in the kernel
/// (e.g. killed/hibernated-out, or running off FreeBSD where enumeration stubs out).
// jail_snapshot:start
//   purpose: Resolve a jail's live jid and PID list from the kernel and pair them
//            with the daemon's tracked AppState.
//   input:  jail_id — validated jail name; states — shared StateMap reference
//   output: (jid, AppState, Vec<i32> pids) — jid is -1 if the jail is not live
//   sideEffects: calls jail_get(2) + sysctl(2) on FreeBSD; reads the state map
fn jail_snapshot(jail_id: &str, states: &StateMap) -> (i32, AppState, Vec<i32>) {
    let state = states.lock().unwrap_or_else(|p| p.into_inner())
        .get(jail_id).cloned().unwrap_or(AppState::Running);

    // Resolve live kernel facts; a missing jail is not an error for STATUS —
    // we just report jid=-1 and no PIDs.
    let (jid, pids) = match jail_enum::jid_by_name(jail_id) {
        Ok(jid) => {
            let pids = jail_enum::jail_pids(jid).unwrap_or_default();
            (jid, pids)
        }
        Err(_) => (-1, Vec::new()),
    };
    (jid, state, pids)
}
// jail_snapshot:end

// status_application:start
//   purpose: Report the real status of a jail: tracked state + live jid + PID list.
//   input:  jail_id — jail name; states — shared StateMap reference
//   output: Result<String, String> (state description with jid and process count)
//   sideEffects: reads state map; calls jail_get(2)/sysctl(2) via jail_snapshot
async fn status_application(jail_id: &str, states: &StateMap) -> Result<String, String> {
    let jail_id = validate_jail_id(jail_id)?;
    let (jid, state, pids) = jail_snapshot(jail_id, states);
    Ok(format!("jail={jail_id} jid={jid} state={state:?} procs={}", pids.len()))
}
// status_application:end

/// Enumerate every live jail from the kernel (jail_get(2) lastjid iteration),
/// each annotated with its current process count (sysctl KERN_PROC_PROC).
// list_jails_text:start
//   purpose: Build a human-readable listing of all live jails: "jid name pids=N"
//            per line, sourced directly from the kernel jail table.
//   input:  none
//   output: Result<String, String> (newline-joined jail lines, or error)
//   sideEffects: calls jail_get(2) per jail + sysctl(2) per jail (FreeBSD); empty off FreeBSD
fn list_jails_text() -> Result<String, String> {
    let jails = jail_enum::list_jails()?;
    if jails.is_empty() {
        return Ok("no live jails".to_string());
    }
    let mut out = String::new();
    for j in &jails {
        let pid_count = jail_enum::jail_pids(j.jid).map(|p| p.len()).unwrap_or(0);
        out.push_str(&format!("jid={} name={} pids={}\n", j.jid, j.name, pid_count));
    }
    Ok(out.trim_end().to_string())
}
// list_jails_text:end

// ── Unix socket сервер ────────────────────────────────────────────────────────

const SOCK_PATH: &str = "/var/run/bsdos-lifecycle.sock";

// handle_conn:start
//   purpose: Handle one Unix socket connection — read one command, dispatch, write response, close.
//   input:  stream — UnixStream; states — StateMap; priorities — PriorityMap
//   output: void; connection closed after one command
//   sideEffects: reads/writes socket, dispatches commands
async fn handle_conn(stream: UnixStream, states: StateMap, priorities: PriorityMap) {
    let (r, mut w) = stream.into_split();
    let mut lines = BufReader::new(r).lines();

    while let Ok(Some(line)) = lines.next_line().await {
        let line = line.trim().to_string();
        if line.is_empty() { continue; }

        let (ok, msg) = dispatch_cmd(&line, &states, &priorities).await;

        let resp = if ok { format!("+OK {msg}\n") } else { format!("-ERR {msg}\n") };
        let _ = w.write_all(resp.as_bytes()).await;
        // Закрываем соединение сразу после ответа (one-command-per-connection).
        // Это позволяет nc получить ответ ДО того как он закроет сокет по EOF stdin.
        // FreeBSD nc закрывает сокет когда stdin (printf) заканчивается — без break
        // nc не успевает прочитать ответ который daemon пишет параллельно.
        break;
    }
}
// handle_conn:end

/// Async диспетчер — signal_jail использует libc syscall'ы (мгновенно),
/// ZFS-команды идут через tokio::process::Command (не блокируют runtime).
// dispatch_cmd:start
//   purpose: Parse a command line and dispatch to the appropriate lifecycle handler.
//   input:  line — command string; states — StateMap; priorities — PriorityMap
//   output: (bool, String) — (success flag, response message)
//   sideEffects: dispatches to freeze/thaw/hibernate/restore/kill/status/list or sets MEM_GUARD
async fn dispatch_cmd(line: &str, states: &StateMap, priorities: &PriorityMap) -> (bool, String) {
    let parts: Vec<&str> = line.split_whitespace().collect();
    match (parts.get(0).copied(), parts.get(1).copied()) {
            (Some("FREEZE"),    Some(id)) => to_result(freeze_application(id, states).await),
            (Some("THAW"),      Some(id)) => to_result(thaw_application(id, states).await),
            (Some("HIBERNATE"), Some(id)) => to_result(hibernate_application(id, states).await),
            (Some("RESTORE"),   Some(id)) => to_result(restore_application(id, states).await),
            (Some("KILL"),      Some(id)) => to_result(kill_application(id, states).await),
            (Some("STATUS"),    Some(id)) => to_result(status_application(id, states).await),

            // LIST — enumerate every live jail (jid + name + pid count) from the kernel.
            (Some("LIST"), _) => to_result(list_jails_text()),

            // SET_PRIORITY <jail_id> <0-255>
            (Some("SET_PRIORITY"), Some(id)) => {
                let prio: u8 = parts.get(2).and_then(|s| s.parse().ok()).unwrap_or(128);
                priorities.lock().unwrap_or_else(|p| p.into_inner()).insert(id.to_string(), JailPriority {
                    jail_id: id.to_string(), priority: prio, last_active: unix_timestamp(),
                });
                (true, format!("jail={id} priority={prio}"))
            }

            // MEM_STATUS
            (Some("MEM_STATUS"), _) => {
                match read_mem_stats() {
                    Ok(s) => (true, format!(
                        "free={:.1}% free_pages={} total_pages={} inactive={}",
                        s.free_pct, s.free_pages, s.total_pages, s.inactive_pages
                    )),
                    Err(e) => (false, e),
                }
            }

            // MEM_GUARD on/off — temporarily disable memory monitor jail kills
            (Some("MEM_GUARD"), Some("on")) => {
                MEM_GUARD_DISABLED.store(false, Ordering::SeqCst);
                eprintln!("[lifecycle] MEM_GUARD: enabled");
                (true, "MEM_GUARD enabled".to_string())
            }

            (Some("MEM_GUARD"), Some("off")) => {
                MEM_GUARD_DISABLED.store(true, Ordering::SeqCst);
                eprintln!("[lifecycle] MEM_GUARD: disabled for 5 minutes");

                // Spawn async timer to auto-re-enable after 5 minutes
                tokio::spawn(async {
                    tokio::time::sleep(Duration::from_secs(300)).await;
                    if MEM_GUARD_DISABLED.compare_exchange(true, false, Ordering::SeqCst, Ordering::SeqCst).is_ok() {
                        eprintln!("[lifecycle] MEM_GUARD: auto-re-enabled after 5 minutes");
                    }
                });

                (true, "MEM_GUARD disabled for 5 minutes".to_string())
            }

            (Some("HELP"), _) => (true,
                "FREEZE|THAW|HIBERNATE|RESTORE|KILL|STATUS <jail_id>\n\
                 LIST                           (enumerate live jails: jid name pids)\n\
                 SET_PRIORITY <jail_id> <0-255>  (0=fg, 255=bg)\n\
                 MEM_STATUS\n\
                 MEM_GUARD on|off               (enable/disable memory monitor kills)".into()),
            _ => (false, format!("unknown: {line}")),
    }
}
// dispatch_cmd:end

// to_result:start
//   purpose: Convert a Result<String, String> into a (bool, String) tuple for response formatting.
//   input:  r — Result<String, String>
//   output: (true, ok_msg) or (false, err_msg)
//   sideEffects: none
fn to_result(r: Result<String, String>) -> (bool, String) {
    match r { Ok(s) => (true, s), Err(e) => (false, e) }
}
// to_result:end

// unix_timestamp:start
//   purpose: Get the current Unix timestamp in seconds since epoch.
//   input:  none
//   output: u64 seconds (0 on error)
//   sideEffects: calls SystemTime::now()
fn unix_timestamp() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}
// unix_timestamp:end

#[tokio::main]
// main:start
//   purpose: Daemon entry — resolve platform lifecycle policy, create Unix socket
//            listener, set up ZFS swap, spawn memory monitor, spawn Zenoh bridge
//            (bsdos/ctl/lifecycle), accept Unix socket connections.
//   input:  none (policy resolved at compile time from BSDOS_PLATFORM cfgs)
//   output: Result<(), Box<dyn std::error::Error>>
//   sideEffects: creates Unix socket at /var/run/bsdos-lifecycle.sock, opens Zenoh session,
//                spawns memory monitor and Zenoh bridge tasks, sets up ZFS swap,
//                conditionally enables ZSTD compression per the platform policy
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Resolve the platform-dependent lifecycle policy (battery → aggressive freeze
    // + ZSTD memory compression; desktop/QEMU → relaxed, compression off). This only
    // governs the automatic memory monitor — manual FREEZE/THAW stays always available.
    let lifecycle_policy = LifecyclePolicy::for_platform();
    eprintln!(
        "[lifecycle] platform={} policy: aggressive_freeze={} memory_compression={} idle_freeze={}s",
        platform_name(),
        lifecycle_policy.aggressive_freeze,
        lifecycle_policy.memory_compression,
        lifecycle_policy.idle_freeze_secs,
    );

    let _ = std::fs::remove_file(SOCK_PATH);
    let listener = UnixListener::bind(SOCK_PATH)?;
    std::fs::set_permissions(SOCK_PATH, std::fs::Permissions::from_mode(0o660))?;
    eprintln!("[lifecycle] bsdOS lifecycle daemon on {SOCK_PATH}");
    eprintln!("[lifecycle] printf 'MEM_STATUS\\n' | nc -U {SOCK_PATH}");

    let states: StateMap = Arc::new(Mutex::new(HashMap::new()));
    let priorities: PriorityMap = Arc::new(Mutex::new(HashMap::new()));

    // Load .jpk descriptors for per-app lifecycle config
    let lifecycle_configs = load_descriptors(&default_zpids_path(), &default_jpk_dir())
        .unwrap_or_else(|e| {
            eprintln!("[lifecycle] jpk config load failed: {e}");
            HashMap::new()
        });
    for (jail_name, cfg) in &lifecycle_configs {
        priorities.lock().unwrap_or_else(|p| p.into_inner()).insert(
            jail_name.clone(),
            JailPriority {
                jail_id: jail_name.clone(),
                priority: cfg.priority,
                last_active: 0,
            },
        );
        eprintln!("[lifecycle] app {} → mem={}MB cpu={}%",
            cfg.app_id, cfg.max_memory_mb, cfg.max_cpu_percent);
    }

    // Per-stream ZSTD compression pool (SPEC §10.3: per-stream for cleaner accounting).
    // Enabled at startup only when the platform policy asks for memory compression
    // (battery devices). On mains-powered platforms it stays off (opt-in later).
    let _zstd_pool = if lifecycle_policy.memory_compression {
        let pool = zstd_pool::create_shared_pool();
        eprintln!("[lifecycle] ZSTD stream pool initialized ({} apps)",
            lifecycle_configs.len());
        Some(pool)
    } else {
        eprintln!("[lifecycle] ZSTD memory compression disabled by platform policy");
        None
    };

    // Настроить ZFS swap (ZSTD через ZFS, ядро page-out автоматически)
    if let Err(e) = setup_zfs_swap() {
        eprintln!("[lifecycle] ZFS swap setup skipped: {e}");
    }

    // Запустить memory monitor в фоне (с платформо-зависимой policy)
    tokio::spawn(memory_monitor::run_monitor(states.clone(), priorities.clone(), lifecycle_policy));

    // Запустить Zenoh bridge в фоне (bsdos/ctl/lifecycle subscriber).
    // Ошибка соединения не роняет демон — логируем и продолжаем.
    {
        let states_z = states.clone();
        tokio::spawn(async move {
            if let Err(e) = zenoh_bridge::run_zenoh_bridge(states_z).await {
                eprintln!("[lifecycle] Zenoh bridge exited: {e}");
            }
        });
    }

    loop {
        let (stream, _) = listener.accept().await?;
        tokio::spawn(handle_conn(stream, states.clone(), priorities.clone()));
    }
}
// main:end
