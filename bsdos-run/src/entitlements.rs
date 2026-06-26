// START_AI_HEADER
// MODULE: bsdos-run/src/entitlements.rs
// PURPOSE: Map iOS entitlements + Info.plist permissions to a bsdOS jail policy.
// INTENT: An iOS app declares what it wants (network, etc.) via entitlements that, for a
//         dev/sideloaded build, surface as keys in the bundle's Info.plist, while the
//         authoritative grants live in embedded.mobileprovision (see mobileprovision.rs).
//         bsdOS runs each app inside a FreeBSD jail.  The jail network model is binary:
//         ip4=inherit (network allowed) vs ip4=disable (network blocked) — see CLAUDE.md.
//         This module collapses the iOS permission surface into a JailPolicy that the runner
//         (and the .jpk bridge) can act on.  When a provisioning profile is present its network
//         grant overrides the Info.plist projection (the profile is the real signed source).
// DEPENDENCIES: plist::BundleInfo, mobileprovision::Entitlements.
// PUBLIC_API: JailPolicy, JailNetwork, policy_from_bundle, policy_from_entitlements.
// END_AI_HEADER

use crate::mobileprovision::Entitlements;
use crate::plist::BundleInfo;

// JailNetwork:start
//   purpose: bsdOS jail network mode — mirrors the ip4=inherit/disable jail(8) knob.
//   input:  decided by policy_from_bundle from entitlement flags.
//   output: Inherit (network allowed) or Disable (network blocked).
//   sideEffects: none.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JailNetwork {
    /// ip4=inherit — the jail shares the host network stack (network allowed).
    Inherit,
    /// ip4=disable — the jail has no network (network blocked).
    Disable,
}

impl JailNetwork {
    // jail_param:start
    //   purpose: Render the network mode as the jail(8) ip4 parameter string.
    //   input:  &self.
    //   output: "inherit" or "disable".
    //   sideEffects: none.
    pub fn jail_param(self) -> &'static str {
        match self {
            JailNetwork::Inherit => "inherit",
            JailNetwork::Disable => "disable",
        }
    }
    // jail_param:end

    // jpk_network:start
    //   purpose: Render the network mode as a .jpk [permissions].network value.
    //   input:  &self.
    //   output: "inet" (Inherit) or "none" (Disable) per SPEC_jpk_descriptor_v1 §3.
    //   sideEffects: none.
    pub fn jpk_network(self) -> &'static str {
        match self {
            JailNetwork::Inherit => "inet",
            JailNetwork::Disable => "none",
        }
    }
    // jpk_network:end
}
// JailNetwork:end

// JailPolicy:start
//   purpose: bsdOS jail sandbox policy derived from an app's declared iOS permissions.
//   input:  built by policy_from_bundle from a BundleInfo.
//   output: network mode + audio/gpu capability flags consumed by the runner / .jpk bridge.
//   sideEffects: none.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct JailPolicy {
    /// Jail network mode (ip4=inherit/disable).
    pub network: JailNetwork,
    /// Whether the app may use audio output (OSS bridge); conservative default false.
    pub audio: bool,
    /// Whether the app declares GPU/GLES needs (Metal/OpenGLES capability → Lima/GLES).
    pub gpu: bool,
}
// JailPolicy:end

// policy_from_bundle:start
//   purpose: Map a parsed Info.plist (BundleInfo) to a bsdOS JailPolicy.
//   input:  bundle — parsed BundleInfo with entitlement-like flags + device capabilities.
//   output: JailPolicy:
//             network = Inherit if any network entitlement is present, else Disable (deny-by-default);
//             gpu     = true if the bundle requires the "metal" or "opengles*" device capability;
//             audio   = false (v1: no audio entitlement surfaced via Info.plist; conservative).
//   sideEffects: none.
pub fn policy_from_bundle(bundle: &BundleInfo) -> JailPolicy {
    // Network: deny by default. Grant only if the app declares a network entitlement.
    // iOS network-client/server entitlements both imply the jail needs the host stack.
    let network = if bundle.network_client || bundle.network_server {
        JailNetwork::Inherit
    } else {
        JailNetwork::Disable
    };

    // GPU: a Metal/GLES device-capability declaration implies the app wants acceleration.
    // We do not have the full UIRequiredDeviceCapabilities list here, so we rely on
    // requires_arm64 only as the arch gate and leave gpu conservative (false) unless a
    // dedicated flag is added. BundleInfo currently exposes arm64; GPU stays false until
    // a graphics capability flag is surfaced. Kept explicit for future extension.
    let gpu = false;

    // Audio: no audio entitlement is surfaced through Info.plist in v1 → conservative false.
    let audio = false;

    JailPolicy { network, audio, gpu }
}
// policy_from_bundle:end

// policy_from_entitlements:start
//   purpose: Derive a JailPolicy from the Info.plist BundleInfo, overlaying an optional
//            embedded.mobileprovision Entitlements as the authoritative network source.
//   input:  bundle — parsed Info.plist; provision — Some(Entitlements) when a profile was parsed,
//           else None (Info.plist-only path).
//   output: JailPolicy:
//             network = Inherit if the provisioning profile grants network (when present),
//                       otherwise falls back to the Info.plist projection (deny-by-default);
//             gpu/audio = same conservative defaults as policy_from_bundle.
//   sideEffects: none.
//   note: the provisioning profile's network grant takes priority over Info.plist because the
//         profile is the signed, authoritative entitlement set.
pub fn policy_from_entitlements(
    bundle: &BundleInfo,
    provision: Option<&Entitlements>,
) -> JailPolicy {
    let mut policy = policy_from_bundle(bundle);

    if let Some(ent) = provision {
        // The profile is authoritative: it can both grant and (by absence) withhold network.
        policy.network = if ent.network {
            JailNetwork::Inherit
        } else {
            JailNetwork::Disable
        };
    }

    policy
}
// policy_from_entitlements:end

#[cfg(test)]
mod tests {
    use super::*;

    // helper:start
    //   purpose: Build a BundleInfo for tests with the given network flags.
    //   input:  client/server network entitlement booleans.
    //   output: BundleInfo.
    //   sideEffects: none.
    fn bundle(network_client: bool, network_server: bool) -> BundleInfo {
        BundleInfo {
            bundle_identifier: "com.example.app".to_string(),
            bundle_executable: "App".to_string(),
            bundle_name: String::new(),
            display_name: String::new(),
            requires_arm64: true,
            minimum_os_version: "13.0".to_string(),
            network_client,
            network_server,
        }
    }
    // helper:end

    #[test]
    fn test_network_client_grants_inherit() {
        let p = policy_from_bundle(&bundle(true, false));
        assert_eq!(p.network, JailNetwork::Inherit);
        assert_eq!(p.network.jail_param(), "inherit");
        assert_eq!(p.network.jpk_network(), "inet");
    }

    #[test]
    fn test_network_server_grants_inherit() {
        let p = policy_from_bundle(&bundle(false, true));
        assert_eq!(p.network, JailNetwork::Inherit);
    }

    #[test]
    fn test_no_network_entitlement_blocks() {
        let p = policy_from_bundle(&bundle(false, false));
        assert_eq!(p.network, JailNetwork::Disable);
        assert_eq!(p.network.jail_param(), "disable");
        assert_eq!(p.network.jpk_network(), "none");
    }

    #[test]
    fn test_defaults_conservative() {
        let p = policy_from_bundle(&bundle(false, false));
        assert!(!p.audio);
        assert!(!p.gpu);
    }

    // ent:start
    //   purpose: Build an Entitlements value for tests with the given network grant.
    //   input:  network — whether the profile grants network.
    //   output: Entitlements.
    //   sideEffects: none.
    fn ent(network: bool) -> Entitlements {
        Entitlements {
            application_identifier: "TEAM.com.example.app".to_string(),
            get_task_allow: true,
            network,
            aps_environment: String::new(),
        }
    }
    // ent:end

    #[test]
    fn test_provision_grants_network_over_plist_deny() {
        // Info.plist says no network, but the signed profile grants it → Inherit.
        let p = policy_from_entitlements(&bundle(false, false), Some(&ent(true)));
        assert_eq!(p.network, JailNetwork::Inherit);
    }

    #[test]
    fn test_provision_denies_network_over_plist_grant() {
        // Info.plist requests network, but the profile withholds it → profile wins (Disable).
        let p = policy_from_entitlements(&bundle(true, false), Some(&ent(false)));
        assert_eq!(p.network, JailNetwork::Disable);
    }

    #[test]
    fn test_no_provision_falls_back_to_plist() {
        // Without a profile, the Info.plist projection decides.
        let p = policy_from_entitlements(&bundle(true, false), None);
        assert_eq!(p.network, JailNetwork::Inherit);
        let p = policy_from_entitlements(&bundle(false, false), None);
        assert_eq!(p.network, JailNetwork::Disable);
    }
}
