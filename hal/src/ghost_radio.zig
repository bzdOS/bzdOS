// START_AI_HEADER
// MODULE: sys-daemon-zig/src/ghost_radio.zig
// PURPOSE: "Ghost Radio" privacy mode — modem is powered off by default and only briefly enabled on a configurable interval to drain pending Matrix/IM pushes, then powered off again so the device drops off the air.
// INTENT: Keep the whole loop in L1 instruction cache and on the stack (no allocator, no heap). GPIO toggles + nanosleeps are the only side effects. A single binary SyncPacket (cmd_id=5) is sent over the HAL socket during each window.
// DEPENDENCIES: std (net, time, debug), libc via @cImport (time/nanosleep, fcntl, unistd, sys/ioctl for the gpioc ioctl).
// PUBLIC_API: GhostConfig (64 B cache-line aligned), power_toggle_modem(state), initiate_stealth_loop(cfg) noreturn, run_default() noreturn, apply_config(interval_min, window_sec, enabled).
// END_AI_HEADER

// bsdOS Ghost Radio Engine — режим приватности эфира.
//
// Алгоритм «Радио-Призрак»:
//   Телефон по умолчанию ВЫКЛЮЧЕН из эфира.
//   Каждые interval_minutes минут — короткое window_seconds-секундное окно:
//     1. GPIO → питание модема ON
//     2. Ждём регистрацию в сети (2 сек)
//     3. CMD_SYNC_MATRIX_PUSH → Rust backend забирает пуши
//     4. GPIO → питание модема OFF
//     5. Телефон снова невидим в эфире
//
// Нет аллокатора, нет heap. nanosleep на уровне ядра. Весь цикл — регистры + стек.
// Целевой бинарь: ~6-8 KB (ReleaseSmall), монопольно в L1 инструкций.

const std = @import("std");
const builtin = @import("builtin");
const log_debug = builtin.mode == .Debug;

const c = @cImport({
    @cInclude("time.h");        // nanosleep, struct timespec
    @cInclude("fcntl.h");       // open
    @cInclude("unistd.h");      // close, write, read
    @cInclude("sys/ioctl.h");   // ioctl для GPIO
    // gpioc.h не включаем — не всегда установлен; используем ioctl напрямую
});

// ── Конфигурация (L2-cache aligned, 64 байта) ─────────────────────────────────

pub const GhostConfig = extern struct {
    interval_minutes: u16 = 15,   // частота просыпания (минуты)
    window_seconds:   u8  = 5,    // время активности окна (секунды)
    ghost_mode:       u8  = 1,    // 1=включён, 0=выключен
    _pad: [60]u8 = .{0} ** 60,    // pad до 64 байт (2+1+1+60=64)

    comptime { std.debug.assert(@sizeOf(GhostConfig) == 64); }
};

// ── GPIO: управление питанием модема ─────────────────────────────────────────
//
// PinePhone: модем EG25-G подключён к PMIC через GPIO (pin ID зависит от схемы).
// Реальный pin: GPIOA pin 14 (EG25_POWER_KEY) — меняется на конкретном hw.
// На QEMU: нет GPIO → пишем в /dev/null с логом.
//
// TODO: уточнить конкретный GPIO-пин по схеме Banana Pi M64 / PinePhone.

const MODEM_GPIO_DEV = "/dev/gpioc0";
// GPIO_PIN_SET ioctl value (из /usr/include/dev/gpio/gpioc.h, _IOW('G', 6, struct gpio_req))
// Определяем вручную чтобы не зависеть от наличия заголовка в пакете gpio-devel
const GPIO_PIN_SET: c_ulong = 0x8008_4706;
const MODEM_GPIO_PIN: u32 = 14;

// power_toggle_modem:start
//   purpose: set the EG25-G modem power GPIO (currently pin 14 on /dev/gpioc0) to 1=ON or 0=OFF via the GPIO_PIN_SET ioctl; on non-FreeBSD or when /dev/gpioc0 is missing the function logs and returns.
//   input:  state — 1 to power up, 0 to power down.
//   output: void; ioctl errors are swallowed (best-effort toggle).
//   sideEffects: opens (and immediately closes) /dev/gpioc0 on FreeBSD; one ioctl(BACKLIGHT_PIN_SET) per call.
pub fn power_toggle_modem(state: u8) void {
    if (log_debug) std.debug.print("[ghost] modem power → {s}\n",
        .{ if (state == 1) "ON" else "OFF" });

    if (builtin.target.os.tag != .freebsd) {
        // Linux/QEMU: нет gpioc → только лог
        return;
    }

    const fd = c.open(MODEM_GPIO_DEV, c.O_RDWR, @as(c_int, 0));
    if (fd < 0) {
        if (log_debug) std.debug.print("[ghost] GPIO open failed (QEMU or no driver)\n", .{});
        return;
    }
    defer _ = c.close(fd);

    // struct gpio_req { uint32_t pin; uint32_t flags; }
    // GPIO_PIN_SET ioctl устанавливает уровень пина
    // Упакованная структура для ioctl
    var req = extern struct { pin: u32, flags: u32 }{
        .pin   = MODEM_GPIO_PIN,
        .flags = state,
    };
    _ = c.ioctl(fd, GPIO_PIN_SET, &req);
}
// power_toggle_modem:end

// ── Бинарный пакет CMD_SYNC_MATRIX_PUSH → бэкенд ─────────────────────────────
//
// Тот же 4-байтовый fixed-size протокол что у guest-agent и предиктивного тача.
// cmd_id=5 = CMD_SYNC_MATRIX_PUSH

const SyncPacket = extern struct {
    cmd_id:  u8 = 5,   // CMD_SYNC_MATRIX_PUSH
    arg_len: u8 = 0,
    payload: u16 = 0,
    comptime { std.debug.assert(@sizeOf(SyncPacket) == 4); }
};

const HAL_SOCK = "/var/run/bsdos-hal.sock";

// send_sync_signal:start
//   purpose: write a 4-byte SyncPacket (cmd_id=CMD_SYNC_MATRIX_PUSH=5) to the HAL socket /var/run/bsdos-hal.sock so the Rust backend drains pending Matrix pushes during the active window.
//   input:  none.
//   output: void; HAL socket not accepting connections is logged and ignored.
//   sideEffects: opens (and immediately closes) a connection to HAL_SOCK; one 4-byte write.
fn send_sync_signal() void {
    const pkt = SyncPacket{};
    const bytes: [4]u8 = @bitCast(pkt);

    const stream = std.net.connectUnixSocket(HAL_SOCK) catch |err| {
        if (log_debug) std.debug.print("[ghost] sync signal failed: {}\n", .{err});
        return;
    };
    defer stream.close();
    stream.writeAll(&bytes) catch {};
    if (log_debug) std.debug.print("[ghost] CMD_SYNC_MATRIX_PUSH sent\n", .{});
}
// send_sync_signal:end

// ── Точное ожидание через nanosleep (не sleep — ядерная точность) ─────────────

// sleep_sec:start
//   purpose: sleep secs seconds via libc nanosleep(2) (kernel-precision, no spin loop).
//   input:  secs — whole seconds to sleep.
//   output: void.
//   sideEffects: blocks the calling thread in the kernel for the requested duration.
fn sleep_sec(secs: u64) void {
    var ts = c.struct_timespec{
        .tv_sec  = @intCast(secs),
        .tv_nsec = 0,
    };
    _ = c.nanosleep(&ts, null);
}
// sleep_sec:end

// sleep_min:start
//   purpose: convenience wrapper — sleep mins*60 seconds via sleep_sec.
//   input:  mins — minutes to sleep (truncated to u16, so max ~18 hours).
//   output: void.
//   sideEffects: blocks the calling thread in the kernel.
fn sleep_min(mins: u16) void {
    sleep_sec(@as(u64, mins) * 60);
}
// sleep_min:end

// ── Окно активности (5 секунд эфира) ─────────────────────────────────────────

// execute_sync_window:start
//   purpose: open one Ghost-Radio sync window — modem power on, 2 s for network registration, send CMD_SYNC_MATRIX_PUSH, sleep the remainder of cfg.window_seconds, then power the modem off.
//   input:  cfg — pointer to the (BSS) GhostConfig describing the window length.
//   output: void.
//   sideEffects: GPIO toggles via power_toggle_modem (2x); 2x nanosleeps (2 s + remainder); one SyncPacket to HAL_SOCK.
fn execute_sync_window(cfg: *const GhostConfig) void {
    if (log_debug) std.debug.print("[ghost] *** SYNC WINDOW OPEN ({d}s) ***\n",
        .{cfg.window_seconds});

    // 1. Питание модема ON
    power_toggle_modem(1);

    // 2. Ждём регистрацию в сети (2 сек)
    sleep_sec(2);

    // 3. Сигнал бэкенду: забрать Matrix-пуши
    send_sync_signal();

    // 4. Ждём пока Rust-бэкенд заберёт данные (остаток window)
    const wait_secs = if (cfg.window_seconds > 3) cfg.window_seconds - 3 else 1;
    sleep_sec(wait_secs);

    // 5. Питание модема OFF → телефон исчезает из эфира
    power_toggle_modem(0);

    if (log_debug) std.debug.print("[ghost] *** SYNC WINDOW CLOSED — phantom mode ***\n", .{});
}
// execute_sync_window:end

// ── Главный stealth-цикл ──────────────────────────────────────────────────────

// initiate_stealth_loop:start
//   purpose: main ghost-radio loop — start with the modem OFF, then forever: sleep cfg.interval_minutes minutes, then (if ghost_mode is on) execute one sync window, otherwise just keep the modem on.
//   input:  cfg — pointer to a GhostConfig (typically the BSS default_cfg).
//   output: noreturn — only exits the process via crash.
//   sideEffects: blocks the thread for the entire lifetime of the HAL; periodic GPIO / HAL socket activity as described in execute_sync_window.
pub fn initiate_stealth_loop(cfg: *const GhostConfig) noreturn {
    if (log_debug) std.debug.print(
        "[ghost] Ghost Radio Engine started: interval={}min window={}s\n",
        .{ cfg.interval_minutes, cfg.window_seconds },
    );

    // Убедиться что модем выключен на старте
    power_toggle_modem(0);

    while (true) {
        // Ждём до следующего окна
        sleep_min(cfg.interval_minutes);

        if (cfg.ghost_mode == 0) {
            // Ghost mode выключен — работаем в обычном режиме
            power_toggle_modem(1);
            continue;
        }

        execute_sync_window(cfg);
        // Цикл завершён: телефон снова невидим на interval_minutes минут
    }
}
// initiate_stealth_loop:end

// ── Публичный API для интеграции с main.zig ───────────────────────────────────

// Статическая конфигурация по умолчанию (BSS, нет heap)
var default_cfg = GhostConfig{};

// Запустить Ghost Radio с дефолтными параметрами
// Вызывать в отдельном потоке из main.zig:
//   const t = try std.Thread.spawn(.{}, ghost.run_default, .{});
// run_default:start
//   purpose: thread entry point — initiate_stealth_loop using the BSS default_cfg (15 min interval, 5 s window, ghost_mode=1).
//   input:  none.
//   output: noreturn.
//   sideEffects: same as initiate_stealth_loop.
pub fn run_default() noreturn {
    initiate_stealth_loop(&default_cfg);
}
// run_default:end

// Применить конфигурацию от внешней команды (через HAL socket)
// apply_config:start
//   purpose: update the live default_cfg in place — used by the HAL socket ghost_config_set command to retune the radio at runtime.
//   input:  interval_min — new sleep between sync windows (minutes); window_sec — new active-window length (seconds, <= 255); enabled — 1 keeps ghost mode, 0 keeps the modem permanently powered on.
//   output: void.
//   sideEffects: mutates the BSS default_cfg; logs the new values in Debug builds.
pub fn apply_config(interval_min: u16, window_sec: u8, enabled: u8) void {
    default_cfg.interval_minutes = interval_min;
    default_cfg.window_seconds   = window_sec;
    default_cfg.ghost_mode       = enabled;
    if (log_debug) std.debug.print("[ghost] config updated: {}min/{}s/enabled={}\n",
        .{ interval_min, window_sec, enabled });
}
// apply_config:end
