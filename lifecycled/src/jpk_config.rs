// START_AI_HEADER
// MODULE: lifecycled/src/jpk_config.rs
// PURPOSE: Parse .jpk descriptors for per-app_id lifecycle configuration.
// INTENT: Read lifecycle settings (max_memory_mb, max_cpu_percent, priority)
//          from jpk.toml descriptors so the lifecycle daemon enforces
//          per-app resource limits declared by the app developer.
// DEPENDENCIES: serde, toml, std::{fs, collections::HashMap}
// PUBLIC_API: JpkDescriptor, JpkRuntime, JpkPermissions, load_descriptors,
//             load_zpids, AppLifecycleConfig
// END_AI_HEADER

// .jpk descriptor reader for the lifecycle daemon.
//
// The lifecycle daemon needs per-app_id config for:
//   - max_memory_mb  → rctl(8) memory limit
//   - max_cpu_percent → rctl(8) CPU limit
//   - jail_name       → which jail to manage
//   - priority hint   → eviction order under memory pressure
//
// Sources:
//   1. /etc/bsdOS/zpids.conf — list of preinstalled app_id = version pairs
//   2. /opt/bsdos/share/jpk/<app_id>/jpk.toml — per-app descriptor
//
// Per SPEC_squirrel_rootfs.md §11.9 + SPEC_jpk_descriptor_v1.md §3.

use serde::Deserialize;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// Subset of jpk.toml [runtime] section relevant to lifecycle management.
#[derive(Debug, Clone, Deserialize)]
pub struct JpkRuntime {
    #[serde(rename = "type")]
    pub runtime_type: String,
    pub jail_name: String,
    pub needs_wayland: bool,
    pub needs_input: bool,
    pub needs_gpu: bool,
}

/// Subset of jpk.toml [permissions] section.
#[derive(Debug, Clone, Deserialize)]
pub struct JpkPermissions {
    pub max_memory_mb: u64,
    pub max_cpu_percent: u8,
    pub max_disk_mb: u64,
}

/// Subset of jpk.toml [meta] section.
#[derive(Debug, Clone, Deserialize)]
pub struct JpkMeta {
    pub id: String,
    pub version: String,
    pub name: String,
}

/// Full descriptor parsed from jpk.toml (only relevant sections).
#[derive(Debug, Clone, Deserialize)]
pub struct JpkDescriptor {
    pub meta: JpkMeta,
    pub runtime: JpkRuntime,
    pub permissions: JpkPermissions,
}

/// Lifecycle-relevant config derived from a .jpk descriptor.
#[derive(Debug, Clone)]
pub struct AppLifecycleConfig {
    pub app_id: String,
    pub jail_name: String,
    pub max_memory_mb: u64,
    pub max_cpu_percent: u8,
    pub priority: u8,
    pub needs_gpu: bool,
}

impl From<&JpkDescriptor> for AppLifecycleConfig {
    fn from(desc: &JpkDescriptor) -> Self {
        // Priority heuristic: apps that need GPU get lower priority (harder to evict).
        // Terminal/console apps get higher priority (easy to restart).
        let priority = if desc.runtime.needs_gpu {
            50 // GPU apps are expensive to restart → keep alive longer
        } else {
            200 // CPU-only apps are cheap to restart → evict first
        };

        Self {
            app_id: desc.runtime.jail_name.clone(),
            jail_name: desc.runtime.jail_name.clone(),
            max_memory_mb: desc.permissions.max_memory_mb,
            max_cpu_percent: desc.permissions.max_cpu_percent,
            priority,
            needs_gpu: desc.runtime.needs_gpu,
        }
    }
}

/// Parse a single jpk.toml file into a JpkDescriptor.
pub fn parse_descriptor(path: &Path) -> Result<JpkDescriptor, String> {
    let content = std::fs::read_to_string(path)
        .map_err(|e| format!("read {}: {e}", path.display()))?;
    toml::from_str(&content)
        .map_err(|e| format!("parse {}: {e}", path.display()))
}

/// Load the zpids.conf file → HashMap<app_name, version>.
pub fn load_zpids(path: &Path) -> Result<HashMap<String, String>, String> {
    let content = std::fs::read_to_string(path)
        .map_err(|e| format!("read {}: {e}", path.display()))?;

    let mut result = HashMap::new();
    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some((key, val)) = line.split_once('=') {
            result.insert(
                key.trim().to_string(),
                val.trim().to_string(),
            );
        }
    }
    Ok(result)
}

/// Load all .jpk descriptors from the jpk registry directory.
/// Returns a map of jail_name → AppLifecycleConfig.
pub fn load_descriptors(
    zpids_path: &Path,
    jpk_dir: &Path,
) -> Result<HashMap<String, AppLifecycleConfig>, String> {
    let mut configs = HashMap::new();

    // Read zpids.conf for the list of installed apps
    let zpids = if zpids_path.exists() {
        load_zpids(zpids_path)?
    } else {
        eprintln!("[jpk] zpids.conf not found at {}, using defaults", zpids_path.display());
        HashMap::new()
    };

    // Try to find jpk.toml for each app
    for (app_name, version) in &zpids {
        let toml_path = jpk_dir.join(app_name).join(version).join("jpk.toml");
        if toml_path.exists() {
            match parse_descriptor(&toml_path) {
                Ok(desc) => {
                    let cfg = AppLifecycleConfig::from(&desc);
                    eprintln!("[jpk] loaded {} v{} → jail={}, mem={}MB, cpu={}%",
                        app_name, version, cfg.jail_name, cfg.max_memory_mb, cfg.max_cpu_percent);
                    configs.insert(cfg.jail_name.clone(), cfg);
                }
                Err(e) => {
                    eprintln!("[jpk] WARN: parse failed for {}: {e}", toml_path.display());
                }
            }
        } else {
            eprintln!("[jpk] {} v{} not found in registry, using defaults", app_name, version);
        }
    }

    // If no descriptors loaded, use sensible defaults for known Squirrel apps
    if configs.is_empty() {
        eprintln!("[jpk] No descriptors found — using Squirrel defaults");
        configs.insert("appTerminal".to_string(), AppLifecycleConfig {
            app_id: "appTerminal".to_string(),
            jail_name: "appTerminal".to_string(),
            max_memory_mb: 32,
            max_cpu_percent: 5,
            priority: 200,
            needs_gpu: false,
        });
        configs.insert("appBrowser".to_string(), AppLifecycleConfig {
            app_id: "appBrowser".to_string(),
            jail_name: "appBrowser".to_string(),
            max_memory_mb: 512,
            max_cpu_percent: 50,
            priority: 50,
            needs_gpu: false,
        });
    }

    Ok(configs)
}

/// Get default paths for Squirrel image layout.
pub fn default_zpids_path() -> PathBuf {
    PathBuf::from("/etc/bsdOS/zpids.conf")
}

pub fn default_jpk_dir() -> PathBuf {
    PathBuf::from("/opt/bsdos/share/jpk")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_zpids() {
        let tmp = std::env::temp_dir().join("test-zpids.conf");
        std::fs::write(&tmp, "# Squirrel\nphantom-browser = 0.1.0\nfoot-terminal = 0.2.0\n").unwrap();
        let zpids = load_zpids(&tmp).unwrap();
        assert_eq!(zpids.get("phantom-browser"), Some(&"0.1.0".to_string()));
        assert_eq!(zpids.get("foot-terminal"), Some(&"0.2.0".to_string()));
        std::fs::remove_file(&tmp).ok();
    }

    #[test]
    fn test_default_configs() {
        let configs = load_descriptors(
            Path::new("/nonexistent/zpids.conf"),
            Path::new("/nonexistent/jpk"),
        ).unwrap();
        // Should fall back to defaults
        assert!(configs.contains_key("appTerminal"));
        assert!(configs.contains_key("appBrowser"));
    }

    #[test]
    fn test_priority_heuristic() {
        let desc = JpkDescriptor {
            meta: JpkMeta { id: "test".into(), version: "1.0".into(), name: "Test".into() },
            runtime: JpkRuntime {
                runtime_type: "jail".into(),
                jail_name: "test".into(),
                needs_wayland: true,
                needs_input: true,
                needs_gpu: true,
            },
            permissions: JpkPermissions {
                max_memory_mb: 256, max_cpu_percent: 30, max_disk_mb: 128,
            },
        };
        let cfg = AppLifecycleConfig::from(&desc);
        assert_eq!(cfg.priority, 50); // GPU app → low priority (keep alive)
    }

    #[test]
    fn test_parse_full_valid_jpk_toml() {
        let tmp = std::env::temp_dir().join("test-valid-jpk.toml");
        std::fs::write(&tmp, r#"
[meta]
schema_version = "1.0"
id              = "org.bsdos.test"
version         = "0.5.0"
name            = "Test App"

[compatibility]
bsdos_codename_min = "Squirrel"
bsdos_codename_max = "Woodpecker"
freebsd_min        = "15.1"
freebsd_max        = "16.0"
arch               = ["amd64", "aarch64"]

[runtime]
type          = "jail"
jail_name     = "appTest"
needs_wayland = true
needs_input   = true
needs_gpu     = false

[permissions]
capabilities    = ["CAP_READ"]
network         = "inet"
filesystem      = "rw"
max_open_files  = 256
max_memory_mb   = 128
max_cpu_percent = 25
max_disk_mb     = 64
network_ingress = false
network_egress  = true
"#).unwrap();

        let desc = parse_descriptor(&tmp).expect("parse valid toml");
        assert_eq!(desc.meta.id, "org.bsdos.test");
        assert_eq!(desc.runtime.jail_name, "appTest");
        assert_eq!(desc.permissions.max_memory_mb, 128);

        let cfg = AppLifecycleConfig::from(&desc);
        assert_eq!(cfg.jail_name, "appTest");
        assert_eq!(cfg.max_memory_mb, 128);
        assert_eq!(cfg.priority, 200); // no GPU → evict first

        std::fs::remove_file(&tmp).ok();
    }

    #[test]
    fn test_zpids_with_comments_and_whitespace() {
        let tmp = std::env::temp_dir().join("test-zpids-messy.conf");
        std::fs::write(&tmp, "\
# Preinstalled .jpk packages
# ============================

  phantom-browser = 0.1.0   

  foot-terminal=0.2.0

# end
").unwrap();

        let zpids = load_zpids(&tmp).unwrap();
        assert_eq!(zpids.len(), 2);
        assert_eq!(zpids.get("phantom-browser"), Some(&"0.1.0".to_string()));
        assert_eq!(zpids.get("foot-terminal"), Some(&"0.2.0".to_string()));

        std::fs::remove_file(&tmp).ok();
    }

    #[test]
    fn test_multiple_apps_different_priorities() {
        // GPU app should have lower priority than CPU-only app
        let gpu_desc = JpkDescriptor {
            meta: JpkMeta { id: "gpu".into(), version: "1".into(), name: "GPU App".into() },
            runtime: JpkRuntime {
                runtime_type: "jail".into(), jail_name: "appGPU".into(),
                needs_wayland: true, needs_input: true, needs_gpu: true,
            },
            permissions: JpkPermissions { max_memory_mb: 256, max_cpu_percent: 40, max_disk_mb: 128 },
        };
        let cpu_desc = JpkDescriptor {
            meta: JpkMeta { id: "cpu".into(), version: "1".into(), name: "CPU App".into() },
            runtime: JpkRuntime {
                runtime_type: "jail".into(), jail_name: "appCPU".into(),
                needs_wayland: false, needs_input: false, needs_gpu: false,
            },
            permissions: JpkPermissions { max_memory_mb: 32, max_cpu_percent: 5, max_disk_mb: 16 },
        };

        let gpu_cfg = AppLifecycleConfig::from(&gpu_desc);
        let cpu_cfg = AppLifecycleConfig::from(&cpu_desc);

        assert!(gpu_cfg.priority < cpu_cfg.priority,
            "GPU app priority {} should be < CPU app priority {} (GPU harder to evict)",
            gpu_cfg.priority, cpu_cfg.priority);
    }

    #[test]
    fn test_invalid_toml_returns_error() {
        let tmp = std::env::temp_dir().join("test-invalid-jpk.toml");
        std::fs::write(&tmp, "this is not = valid [toml [[[").unwrap();

        let result = parse_descriptor(&tmp);
        assert!(result.is_err(), "invalid TOML should return Err, not panic");

        std::fs::remove_file(&tmp).ok();
    }

    #[test]
    fn test_missing_file_returns_error() {
        let result = parse_descriptor(Path::new("/nonexistent/path/to/jpk.toml"));
        assert!(result.is_err());
    }

    #[test]
    fn test_load_descriptors_with_real_toml() {
        let tmp = std::env::temp_dir().join("test-load-descriptors");
        let app_dir = tmp.join("phantom-browser").join("0.1.0");
        std::fs::create_dir_all(&app_dir).unwrap();
        std::fs::write(app_dir.join("jpk.toml"), r#"
[meta]
schema_version = "1.0"
id = "org.bsdos.phantom-browser"
version = "0.1.0"
name = "Phantom Browser"

[compatibility]
bsdos_codename_min = "Squirrel"
bsdos_codename_max = "Woodpecker"
freebsd_min = "15.1"
freebsd_max = "16.0"
arch = ["amd64"]

[runtime]
type = "jail"
jail_name = "appBrowser"
needs_wayland = true
needs_input = true
needs_gpu = false

[permissions]
capabilities = []
network = "inet"
filesystem = "ro"
max_open_files = 256
max_memory_mb = 256
max_cpu_percent = 30
max_disk_mb = 128
network_ingress = false
network_egress = true
"#).unwrap();

        let zpids_path = tmp.join("zpids.conf");
        std::fs::write(&zpids_path, "phantom-browser = 0.1.0\n").unwrap();

        let configs = load_descriptors(&zpids_path, &tmp).unwrap();
        assert!(configs.contains_key("appBrowser"), "should have appBrowser");
        let cfg = &configs["appBrowser"];
        assert_eq!(cfg.max_memory_mb, 256);
        assert_eq!(cfg.max_cpu_percent, 30);

        // cleanup
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn test_load_descriptors_missing_toml_uses_defaults() {
        let zpids_path = std::env::temp_dir().join("test-zpids-noapp.conf");
        std::fs::write(&zpids_path, "nonexistent-app = 9.9.9\n").unwrap();

        let configs = load_descriptors(&zpids_path, Path::new("/nonexistent/jpk")).unwrap();
        // The TOML doesn't exist, so configs is empty → fallback defaults are inserted.
        assert!(configs.contains_key("appTerminal"));
        assert!(configs.contains_key("appBrowser"));

        std::fs::remove_file(&zpids_path).ok();
    }

    #[test]
    fn test_cpu_only_app_high_priority() {
        let desc = JpkDescriptor {
            meta: JpkMeta { id: "term".into(), version: "1".into(), name: "Terminal".into() },
            runtime: JpkRuntime {
                runtime_type: "jail".into(), jail_name: "appTerminal".into(),
                needs_wayland: true, needs_input: true, needs_gpu: false,
            },
            permissions: JpkPermissions { max_memory_mb: 32, max_cpu_percent: 5, max_disk_mb: 16 },
        };
        let cfg = AppLifecycleConfig::from(&desc);
        assert_eq!(cfg.priority, 200); // CPU-only → high priority (evict first)
        assert_eq!(cfg.max_memory_mb, 32);
    }
}
