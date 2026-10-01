// START_AI_HEADER
// MODULE: guest-agent/src/svc_id.zig
// PURPOSE: bsdOS vsock service identifier definitions — hash-based deterministic port allocation.
// INTENT: Avoid magic-number service ports; use compile-time hashed names for AF_VSOCK service selectors.
// DEPENDENCIES: none (pure comptime)
// PUBLIC_API: svc(), BSDOS_AGENT, BSDOS_HAL, BSDOS_LIFECYCLE, BSDOS_TELEMETRY
// END_AI_HEADER

// bsdOS vsock service identifiers.
// Не TCP-порты — идентификаторы сервисов AF_VSOCK.
// CID назначает гипервизор; port здесь = service selector.
//
// Формат: не числа в коде — только имена.

/// Главный управляющий агент bsdOS
pub const BSDOS_AGENT: u32 = svc("bsdos.agent");

/// HAL daemon (Zig) — системные события
pub const BSDOS_HAL: u32 = svc("bsdos.hal");

/// Lifecycle daemon (Rust) — FREEZE/THAW
pub const BSDOS_LIFECYCLE: u32 = svc("bsdos.lifecycle");

/// Telemetry stream (Cap'n Proto)
pub const BSDOS_TELEMETRY: u32 = svc("bsdos.telemetry");

/// Compile-time hash строки → u32 service port.
/// Детерминированный, нет магических чисел в коде.
// svc:start
//   purpose: Compile-time FNV-1a hash of a service name string into a vsock port in the 0x4000_0000+ range.
//   input:  name — comptime string slice (service name)
//   output: u32 vsock service identifier
//   sideEffects: none
fn svc(comptime name: []const u8) u32 {
    comptime {
        var h: u32 = 0x811c9dc5;
        for (name) |byte| {
            h ^= @as(u32, byte);
            h *%= 0x01000193;
        }
        // vsock reserved range: 0-1023 зарезервированы.
        // Наши сервисы: 0x4000_0000+ (верхняя половина пространства)
        return (h | 0x4000_0000) & 0x7FFF_FFFF;
    }
}
// svc:end
