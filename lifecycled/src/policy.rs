// START_AI_HEADER
// MODULE: lifecycled/src/policy.rs
// PURPOSE: Platform-dependent lifecycle policy — freeze timing + memory compression
//          selection derived at compile time from BSDOS_PLATFORM capability cfgs.
// INTENT: On battery-powered platforms (PinePhone, cfg(bsdos_has_battery)) the
//          daemon runs an aggressive policy: freeze idle jails sooner and enable
//          per-stream ZSTD memory compression. On mains-powered desktop/QEMU guests
//          (no battery) it runs a relaxed policy: freeze on demand only, compression
//          off by default. Manual FREEZE/THAW over Zenoh / Unix socket stays available
//          regardless of policy — this only governs the *automatic* memory monitor.
// DEPENDENCIES: none (pure compile-time selection; cfgs declared in platform_build.rs).
// PUBLIC_API: LifecyclePolicy, LifecyclePolicy::for_platform(), platform_name().
// END_AI_HEADER

// Platform-aware lifecycle policy.
//
// The policy is resolved entirely at compile time from the capability cfgs that
// `infra/rust/platform_build.rs` emits (mirrors sys-daemon-zig/src/platform.zig):
//   - cfg(bsdos_has_battery)  → pinephone only → aggressive, compression on
//   - everything else (qemu_amd64 / qemu_aarch64 / bpi_m64) → relaxed, compression off
//
// Battery-aware rationale: on a phone, idle background jails burning CPU or holding
// uncompressed RAM directly costs battery life, so we freeze them quickly (30s) and
// compress stream memory. On a plugged-in dev box neither cost matters, so we keep
// the soft 5-minute idle window and leave compression opt-in (manual / pressure-driven).

/// Platform-dependent lifecycle policy.
///
/// Resolved once at startup via [`LifecyclePolicy::for_platform`]; the chosen
/// variant is fixed at compile time by the active `BSDOS_PLATFORM` capability cfgs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LifecyclePolicy {
    /// Freeze idle background jails proactively (battery platforms) vs. on demand only.
    pub aggressive_freeze: bool,
    /// Enable per-stream ZSTD memory compression at startup.
    pub memory_compression: bool,
    /// Idle window before a background jail becomes a freeze candidate (seconds).
    pub idle_freeze_secs: u64,
}

impl LifecyclePolicy {
    // for_platform:start
    //   purpose: Build the lifecycle policy for the compiled-in platform — aggressive
    //            freeze + memory compression on battery devices, relaxed otherwise.
    //   input:   none (selection is purely compile-time via cfg(bsdos_has_battery)).
    //   output:  LifecyclePolicy with the platform-appropriate field values.
    //   sideEffects: none.
    pub fn for_platform() -> Self {
        #[cfg(bsdos_has_battery)]
        {
            // Battery-powered (PinePhone): conserve power — freeze fast, compress RAM.
            Self {
                aggressive_freeze: true,
                memory_compression: true,
                idle_freeze_secs: 30,
            }
        }
        #[cfg(not(bsdos_has_battery))]
        {
            // Mains-powered (QEMU dev loop / Banana Pi): relaxed — freeze on demand only.
            Self {
                aggressive_freeze: false,
                memory_compression: false,
                idle_freeze_secs: 300,
            }
        }
    }
    // for_platform:end
}

// platform_name:start
//   purpose: Return the compiled-in platform identifier as a human-readable string
//            for startup logging (mirrors the BSDOS_PLATFORM value).
//   input:   none (selection is compile-time via cfg(bsdos_platform = "...")).
//   output:  &'static str — one of qemu_amd64 / qemu_aarch64 / bpi_m64 / pinephone,
//            or "unknown" if no platform cfg is active.
//   sideEffects: none.
pub fn platform_name() -> &'static str {
    #[cfg(bsdos_platform = "qemu_amd64")]
    {
        return "qemu_amd64";
    }
    #[cfg(bsdos_platform = "qemu_aarch64")]
    {
        return "qemu_aarch64";
    }
    #[cfg(bsdos_platform = "bpi_m64")]
    {
        return "bpi_m64";
    }
    #[cfg(bsdos_platform = "pinephone")]
    {
        return "pinephone";
    }
    #[allow(unreachable_code)]
    {
        "unknown"
    }
}
// platform_name:end

#[cfg(test)]
mod tests {
    use super::*;

    // Only the policy for the platform this build targets can be exercised at
    // runtime (the other arm is compiled out). We assert the current build's
    // policy is self-consistent; the opposite arm is covered by the fact that
    // both arms must compile (cfg gate) under their respective BSDOS_PLATFORM.

    #[test]
    fn test_policy_internally_consistent() {
        let p = LifecyclePolicy::for_platform();
        // aggressive_freeze and memory_compression move together by design:
        // both true on battery, both false otherwise.
        assert_eq!(p.aggressive_freeze, p.memory_compression);
        // The idle window must be positive in every configuration.
        assert!(p.idle_freeze_secs > 0);
    }

    #[test]
    fn test_policy_matches_battery_cfg() {
        let p = LifecyclePolicy::for_platform();

        #[cfg(bsdos_has_battery)]
        {
            assert!(p.aggressive_freeze, "battery platform must freeze aggressively");
            assert!(p.memory_compression, "battery platform must compress memory");
            assert_eq!(p.idle_freeze_secs, 30);
        }
        #[cfg(not(bsdos_has_battery))]
        {
            assert!(!p.aggressive_freeze, "non-battery platform freezes on demand only");
            assert!(!p.memory_compression, "non-battery platform leaves compression off");
            assert_eq!(p.idle_freeze_secs, 300);
        }
    }

    #[test]
    fn test_platform_name_known() {
        // platform_name() must resolve to a recognised identifier (never "unknown"
        // in a normal build — platform_build.rs always emits one bsdos_platform cfg).
        let name = platform_name();
        assert!(
            matches!(
                name,
                "qemu_amd64" | "qemu_aarch64" | "bpi_m64" | "pinephone"
            ),
            "unexpected platform name: {name}"
        );
    }

    #[test]
    fn test_policy_is_copy() {
        // LifecyclePolicy is Copy — cheap to pass into the monitor loop by value.
        let p = LifecyclePolicy::for_platform();
        let q = p;
        assert_eq!(p, q);
    }
}
