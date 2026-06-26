// START_AI_HEADER
// MODULE: lifecycled/src/memory_monitor.rs
// PURPOSE: bsdOS Memory Monitor — periodic RAM pressure check with proactive jail lifecycle actions before OOM.
// INTENT: Prevent OOM by freezing/hibernating/killing low-priority jails based on sysctl vm.stats thresholds.
// DEPENDENCIES: std::process::Command, std::sync::{Arc, Mutex}, crate::policy::LifecyclePolicy,
//               crate::{freeze_application, hibernate_application, kill_application}
// PUBLIC_API: read_mem_stats(), setup_zfs_swap(), run_monitor(), MemPressure, MemStats, JailPriority, PriorityMap
// END_AI_HEADER

// bsdOS Memory Monitor — следит за RAM и триггерит lifecycle actions до OOM.
//
// FreeBSD swap reality:
//   Мы не сериализуем RAM вручную (нет CRIU на FreeBSD userspace).
//   Вместо этого: ZFS ZVOL как swap-устройство → ядро само page-out через VM.
//   ZFS на zvol даёт ZSTD-компрессию прозрачно.
//   Наша роль: FREEZE малоприоритетные jails до того как ядро начнёт OOM.
//
// Пороги (конфигурируемые):
//   WARN  (50% RAM свободно) — freeze низкоприоритетных jails
//   CRIT  (20% RAM свободно) — hibernate + kill jails (реально освобождает RAM)
//   OOM   (5%  RAM свободно) — emergency kill, спасаем только foreground

use crate::policy::LifecyclePolicy;
use crate::{freeze_application, hibernate_application, kill_application};
use std::collections::HashMap;
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// Приоритет jail: чем выше число, тем раньше выгружается при нехватке RAM
#[derive(Debug, Clone)]
pub struct JailPriority {
    pub jail_id: String,
    pub priority: u8,  // 0=foreground, 255=background
    pub last_active: u64,
}

pub type PriorityMap = Arc<Mutex<HashMap<String, JailPriority>>>;

/// Статистика памяти FreeBSD (из sysctl vm.stats)
#[derive(Debug)]
pub struct MemStats {
    pub total_pages: u64,
    pub free_pages: u64,
    pub inactive_pages: u64,
    pub free_pct: f32,
}

/// Читает статистику памяти через sysctl (без /proc — это FreeBSD)
// read_mem_stats:start
//   purpose: Read FreeBSD memory statistics via sysctl vm.stats.vm.* and return MemStats.
//   input:  none
//   output: Result<MemStats, String> (parsed stats or error)
//   sideEffects: spawns sysctl commands
pub fn read_mem_stats() -> Result<MemStats, String> {
    let total = sysctl_u64("vm.stats.vm.v_page_count")?;
    let free  = sysctl_u64("vm.stats.vm.v_free_count")?;
    let inactive = sysctl_u64("vm.stats.vm.v_inactive_count")?;
    let free_pct = if total > 0 { (free as f32 / total as f32) * 100.0 } else { 100.0 };
    Ok(MemStats { total_pages: total, free_pages: free, inactive_pages: inactive, free_pct })
}
// read_mem_stats:end

// sysctl_u64:start
//   purpose: Read a FreeBSD sysctl key as a u64 value by spawning sysctl -n.
//   input:  key — sysctl MIB name (e.g. "vm.stats.vm.v_page_count")
//   output: Result<u64, String> (value or error)
//   sideEffects: spawns a sysctl process
fn sysctl_u64(key: &str) -> Result<u64, String> {
    let out = Command::new("sysctl")
        .args(["-n", key])
        .output()
        .map_err(|e| format!("sysctl {key}: {e}"))?;
    String::from_utf8_lossy(&out.stdout)
        .trim()
        .parse::<u64>()
        .map_err(|e| format!("parse {key}: {e}"))
}
// sysctl_u64:end

/// Уровень тревоги по памяти
#[derive(Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum MemPressure {
    Normal,   // >50% свободно
    Warn,     // 20-50%: freeze background
    Critical, // 5-20%: hibernate + kill
    Oom,      // <5%: emergency kill
}

impl MemPressure {
    // from_stats:start
//   purpose: Classify memory pressure level from free page percentage.
//   input:  stats — reference to MemStats
//   output: MemPressure variant (Normal/Warn/Critical/Oom)
//   sideEffects: none
    pub fn from_stats(stats: &MemStats) -> Self {
        match stats.free_pct as u32 {
            51..=100 => MemPressure::Normal,
            21..=50  => MemPressure::Warn,
            6..=20   => MemPressure::Critical,
            _        => MemPressure::Oom,
        }
    }
    // from_stats:end
}

/// Отсортировать jails от наименее до наиболее приоритетных (кандидаты на выгрузку)
// eviction_candidates:start
//   purpose: Sort tracked jails by priority descending and last_active ascending — least important first.
//   input:  priorities — shared PriorityMap reference
//   output: Vec<String> of jail IDs in eviction order
//   sideEffects: acquires mutex lock on priorities
fn eviction_candidates(priorities: &PriorityMap) -> Vec<String> {
    let mut jails: Vec<_> = match priorities.lock() {
        Ok(g) => g.values().cloned().collect(),
        Err(_) => return Vec::new(),
    };
    // Сортировка: высокий priority + давно не активный → выгружается первым
    jails.sort_by(|a, b| {
        b.priority.cmp(&a.priority)
            .then(a.last_active.cmp(&b.last_active))
    });
    jails.into_iter().map(|j| j.jail_id).collect()
}
// eviction_candidates:end

/// Текущее unix-время в секундах (для idle-расчётов).
// unix_now:start
//   purpose: Get the current Unix timestamp in seconds since epoch for idle comparisons.
//   input:  none
//   output: u64 seconds (0 on clock error)
//   sideEffects: reads the system clock
fn unix_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}
// unix_now:end

/// Проверка: простаивает ли jail дольше idle-порога policy.
// is_idle_past:start
//   purpose: Decide whether a jail's last-active timestamp is older than the policy
//            idle window, i.e. it is a proactive-freeze candidate.
//   input:  priorities — PriorityMap; jail_id — jail name; idle_secs — idle window;
//           now — current unix timestamp (seconds)
//   output: bool — true if last_active is more than idle_secs in the past (or unknown)
//   sideEffects: acquires mutex lock on priorities briefly
fn is_idle_past(priorities: &PriorityMap, jail_id: &str, idle_secs: u64, now: u64) -> bool {
    let last_active = match priorities.lock() {
        Ok(g) => g.get(jail_id).map(|p| p.last_active),
        Err(_) => None,
    };
    match last_active {
        // Treat last_active==0 (never marked active) as idle — safe to freeze proactively.
        Some(0) | None => true,
        Some(ts) => now.saturating_sub(ts) >= idle_secs,
    }
}
// is_idle_past:end

/// Главный цикл мониторинга памяти
// run_monitor:start
//   purpose: Main async loop — every 5s read mem stats, evaluate pressure, freeze/hibernate/kill
//            jails per the platform policy (aggressive proactive freeze on battery, on-demand otherwise).
//   input:  states — StateMap; priorities — PriorityMap; policy — platform LifecyclePolicy
//   output: never (infinite loop)
//   sideEffects: calls freeze_application, hibernate_application, kill_application based on pressure level
pub async fn run_monitor(
    states: crate::StateMap,
    priorities: PriorityMap,
    policy: LifecyclePolicy,
) {
    let mut last_pressure = MemPressure::Normal;

    loop {
        tokio::time::sleep(Duration::from_secs(5)).await;

        let stats = match read_mem_stats() {
            Ok(s) => s,
            Err(e) => { eprintln!("[mem] read error: {e}"); continue; }
        };

        let pressure = MemPressure::from_stats(&stats);
        let candidates = eviction_candidates(&priorities);

        // Check if memory guard is disabled (prevents jail kills)
        let should_skip_kills = crate::MEM_GUARD_DISABLED.load(std::sync::atomic::Ordering::SeqCst);

        if pressure != last_pressure {
            eprintln!(
                "[mem] pressure={:?} free={:.1}% ({}/{} pages)",
                pressure, stats.free_pct, stats.free_pages, stats.total_pages
            );
        }

        match pressure {
            MemPressure::Normal => {
                // Ничего не делаем
            }

            MemPressure::Warn => {
                // Proactive freeze of low-priority jails is only done when the platform
                // policy is aggressive (battery devices). On mains-powered platforms WARN
                // is informational — jails are frozen on demand, not pre-emptively.
                if policy.aggressive_freeze {
                    let now = unix_now();
                    // Freeze наименее приоритетных (без Kill — RAM не освобождается,
                    // но CPU освобождается и ядро может page-out inactive pages в ZFS swap).
                    // Только те, что простаивают дольше policy.idle_freeze_secs.
                    for jail_id in candidates.iter().take(2) {
                        if !is_idle_past(&priorities, jail_id, policy.idle_freeze_secs, now) {
                            continue;
                        }
                        let st = match states.lock() { Ok(g) => g, Err(_) => return }.get(jail_id.as_str()).cloned();
                        if st == Some(crate::AppState::Running) {
                            eprintln!("[mem] WARN: freezing {jail_id} (idle > {}s)", policy.idle_freeze_secs);
                            let _ = freeze_application(jail_id, &states).await;
                        }
                    }
                } else if last_pressure != MemPressure::Warn {
                    eprintln!("[mem] WARN: relaxed policy — no proactive freeze (freeze on demand only)");
                }
            }

            MemPressure::Critical => {
                // Hibernate (ZFS snapshot) + kill → реально освобождает RAM.
                // Процесс убит, контекст ФС сохранён в snapshot для rollback.
                // Skip if MEM_GUARD is disabled
                if should_skip_kills {
                    eprintln!("[mem] CRITICAL: skipping jail kills (MEM_GUARD disabled)");
                } else {
                    for jail_id in candidates.iter().take(1) {
                        let st = match states.lock() { Ok(g) => g, Err(_) => return }.get(jail_id.as_str()).cloned();
                        if matches!(st, Some(crate::AppState::Running) | Some(crate::AppState::Frozen)) {
                            eprintln!("[mem] CRITICAL: hibernating+killing {jail_id}");
                            let _ = hibernate_application(jail_id, &states).await;
                            // После snapshot — kill чтобы реально освободить RAM
                            let _ = kill_application(jail_id, &states).await;
                        }
                    }
                }
            }

            MemPressure::Oom => {
                // Emergency: убиваем всех кандидатов кроме foreground (priority=0)
                // Skip if MEM_GUARD is disabled
                if should_skip_kills {
                    eprintln!("[mem] OOM EMERGENCY: skipping jail kills (MEM_GUARD disabled)");
                } else {
                    eprintln!("[mem] OOM EMERGENCY: killing background jails");
                    for jail_id in &candidates {
                        let is_foreground = priorities.lock().unwrap_or_else(|p| p.into_inner())
                            .get(jail_id.as_str())
                            .map(|p| p.priority == 0)
                            .unwrap_or(false);
                        if !is_foreground {
                            let _ = kill_application(jail_id, &states).await;
                        }
                    }
                }
            }
        }

        last_pressure = pressure;
    }
}
// run_monitor:end

/// Установить ZFS ZVOL как swap (вызывается при старте демона)
/// Предполагает что датасет bsdos/swap уже создан:
///   zfs create -V 2G -o compression=zstd bsdos/swap
// setup_zfs_swap:start
//   purpose: Ensure bsdos/swap ZVOL exists (create if missing) and enable as swap device.
//   input:  none
//   output: Result<(), String>
//   sideEffects: spawns zfs create and swapon commands
pub fn setup_zfs_swap() -> Result<(), String> {
    // Проверить существует ли zvol
    let check = Command::new("zfs")
        .args(["list", "bsdos/swap"])
        .output()
        .map_err(|e| format!("zfs list: {e}"))?;

    if !check.status.success() {
        eprintln!("[mem] bsdos/swap zvol not found, creating 2G...");
        Command::new("zfs")
            .args(["create", "-V", "2G", "-o", "compression=zstd",
                   "-o", "logbias=throughput", "bsdos/swap"])
            .output()
            .map_err(|e| format!("zfs create: {e}"))?;
    }

    // Подключить как swap device
    let dev = "/dev/zvol/bsdos/swap";
    let out = Command::new("swapon")
        .arg(dev)
        .output()
        .map_err(|e| format!("swapon: {e}"))?;

    if out.status.success() {
        eprintln!("[mem] ZFS swap enabled: {dev} (ZSTD compression via ZFS)");
    } else {
        let err = String::from_utf8_lossy(&out.stderr);
        if err.contains("already") || err.contains("busy") {
            eprintln!("[mem] ZFS swap already active");
        } else {
            return Err(format!("swapon failed: {err}"));
        }
    }
    Ok(())
}
// setup_zfs_swap:end
