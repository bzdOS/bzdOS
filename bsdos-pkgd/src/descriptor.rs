// START_AI_HEADER
// MODULE: bsdos-pkgd/src/descriptor.rs
// PURPOSE: JpkDescriptor — canonical jpk.toml struct for .jpk packages.
// INTENT: Parse, validate, and serialise the full SPEC_jpk_descriptor_v1 schema.
// DEPENDENCIES: serde, toml, thiserror.
// PUBLIC_API: JpkDescriptor, JpkMeta, JpkCompatibility, JpkRuntime, JpkPermissions,
//             JpkBuild, JpkUpdate, JpkDiscovery, JpkDescriptor::from_toml_str,
//             JpkDescriptor::validate, validate_app_id, validate_semver.
// END_AI_HEADER

use serde::{Deserialize, Serialize};
use thiserror::Error;

// ── Error ────────────────────────────────────────────────────────────────────

#[derive(Debug, Error)]
pub enum DescriptorError {
    #[error("TOML parse error: {0}")]
    TomlParse(#[from] toml::de::Error),

    #[error("TOML serialise error: {0}")]
    TomlSerialise(#[from] toml::ser::Error),

    #[error("validation error: {0}")]
    Validation(String),
}

// ── Sub-sections ─────────────────────────────────────────────────────────────

/// [meta] — package metadata (required).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct JpkMeta {
    /// Schema version, must be "1.0".
    pub schema_version: String,
    /// Reverse-DNS unique identifier, e.g. "org.bsdos.firefox".
    pub id: String,
    /// SemVer version string.
    pub version: String,
    /// Human-readable name.
    pub name: String,
    /// Short description.
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub homepage: String,
    #[serde(default)]
    pub license: String,
    #[serde(default)]
    pub authors: Vec<String>,
    #[serde(default)]
    pub maintainer: String,
}

/// [compatibility] — bsdOS codename + FreeBSD version + arch (required).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct JpkCompatibility {
    /// Earliest supported bsdOS codename (e.g. "Squirrel").
    pub bsdos_codename_min: String,
    /// Latest tested codename (e.g. "Porcupine").
    #[serde(default)]
    pub bsdos_codename_max: String,
    /// Minimum FreeBSD version, e.g. "15.1".
    pub freebsd_min: String,
    /// Maximum FreeBSD version (exclusive), e.g. "16.0".
    #[serde(default)]
    pub freebsd_max: String,
    /// Supported CPU architectures: "aarch64", "amd64", "any".
    pub arch: Vec<String>,
}

/// [runtime] — topology declaration (required).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct JpkRuntime {
    /// Runtime type. Currently only "jail" is supported.
    #[serde(rename = "type")]
    pub runtime_type: String,
    /// FreeBSD jail name.
    #[serde(default)]
    pub jail_name: String,
    /// Application entrypoint binary path.
    pub entrypoint: String,
    #[serde(default)]
    pub needs_wayland: bool,
    #[serde(default)]
    pub needs_input: bool,
    #[serde(default)]
    pub needs_gpu: bool,
    #[serde(default)]
    pub needs_audio: bool,
    #[serde(default)]
    pub needs_modem: bool,
}

/// [permissions] — sandboxing and resource limits (required).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct JpkPermissions {
    /// Capsicum capability rights list.
    #[serde(default)]
    pub capabilities: Vec<String>,
    /// Network access: "none" | "inet" | "inet6" | "unix-only".
    #[serde(default = "default_none_str")]
    pub network: String,
    /// Filesystem access: "ro" | "rw" | "private-tmpfs".
    #[serde(default = "default_ro_str")]
    pub filesystem: String,
    #[serde(default)]
    pub max_open_files: Option<u32>,
    #[serde(default)]
    pub max_memory_mb: Option<u32>,
    #[serde(default)]
    pub max_cpu_percent: Option<u32>,
    #[serde(default)]
    pub max_disk_mb: Option<u32>,
    #[serde(default)]
    pub network_ingress: bool,
    #[serde(default)]
    pub network_egress: bool,
}

fn default_none_str() -> String {
    "none".to_string()
}

fn default_ro_str() -> String {
    "ro".to_string()
}

/// [build] — build provenance (required).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct JpkBuild {
    #[serde(default)]
    pub source_url: String,
    #[serde(default)]
    pub source_commit: String,
    #[serde(default)]
    pub build_host: String,
    #[serde(default)]
    pub build_timestamp: String,
    #[serde(default)]
    pub build_user: String,
    #[serde(default)]
    pub freebsd_version: String,
    #[serde(default)]
    pub reproducible: bool,
}

/// [update] — update channel configuration (optional).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct JpkUpdate {
    #[serde(default = "default_stable_str")]
    pub channel: String,
    #[serde(default)]
    pub auto_update: bool,
    #[serde(default)]
    pub deprecates: Vec<String>,
}

fn default_stable_str() -> String {
    "stable".to_string()
}

/// [discovery] — app store discovery metadata (optional).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct JpkDiscovery {
    #[serde(default)]
    pub keywords: Vec<String>,
    #[serde(default)]
    pub category: String,
    #[serde(default)]
    pub screenshot: String,
    #[serde(default)]
    pub icon: String,
}

// ── Root descriptor ──────────────────────────────────────────────────────────

/// Full jpk.toml descriptor as specified in SPEC_jpk_descriptor_v1.md §3.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct JpkDescriptor {
    pub meta: JpkMeta,
    pub compatibility: JpkCompatibility,
    pub runtime: JpkRuntime,
    pub permissions: JpkPermissions,
    #[serde(default)]
    pub build: Option<JpkBuild>,
    #[serde(default)]
    pub update: Option<JpkUpdate>,
    #[serde(default)]
    pub discovery: Option<JpkDiscovery>,
}

impl JpkDescriptor {
    // from_toml_str:start
    //   purpose: Parse jpk.toml content from a string into a JpkDescriptor.
    //   input:  s: TOML string content.
    //   output: Result<JpkDescriptor, DescriptorError>.
    //   sideEffects: none.
    pub fn from_toml_str(s: &str) -> Result<Self, DescriptorError> {
        let desc: Self = toml::from_str(s)?;
        Ok(desc)
    }
    // from_toml_str:end

    // to_toml_string:start
    //   purpose: Serialise JpkDescriptor back to a TOML string.
    //   input:  &self.
    //   output: Result<String, DescriptorError>.
    //   sideEffects: none.
    pub fn to_toml_string(&self) -> Result<String, DescriptorError> {
        Ok(toml::to_string_pretty(self)?)
    }
    // to_toml_string:end

    // validate:start
    //   purpose: Validate all required fields per SPEC §6 validation rules.
    //   input:  &self.
    //   output: Result<(), DescriptorError> — Ok if valid, Err with first violation.
    //   sideEffects: none.
    pub fn validate(&self) -> Result<(), DescriptorError> {
        // Rule 3: schema_version must be "1.0"
        if self.meta.schema_version != "1.0" {
            return Err(DescriptorError::Validation(format!(
                "unsupported schema_version '{}', expected '1.0'",
                self.meta.schema_version
            )));
        }

        // Rule 4: id format — reverse-DNS, lowercase, no special chars
        validate_app_id(&self.meta.id)
            .map_err(|e| DescriptorError::Validation(format!("meta.id: {e}")))?;

        // Rule 5: semver version
        validate_semver(&self.meta.version)
            .map_err(|e| DescriptorError::Validation(format!("meta.version: {e}")))?;

        // Rule: arch list non-empty
        if self.compatibility.arch.is_empty() {
            return Err(DescriptorError::Validation(
                "compatibility.arch must not be empty".to_string(),
            ));
        }

        // Rule: runtime type must be "jail" in v1
        if self.runtime.runtime_type != "jail" {
            return Err(DescriptorError::Validation(format!(
                "runtime.type '{}' not supported in schema v1.0 (only 'jail')",
                self.runtime.runtime_type
            )));
        }

        // Rule: entrypoint non-empty
        if self.runtime.entrypoint.is_empty() {
            return Err(DescriptorError::Validation(
                "runtime.entrypoint must not be empty".to_string(),
            ));
        }

        // Rule: permissions.network valid value
        let valid_network = ["none", "inet", "inet6", "unix-only"];
        if !valid_network.contains(&self.permissions.network.as_str()) {
            return Err(DescriptorError::Validation(format!(
                "permissions.network '{}' must be one of: {}",
                self.permissions.network,
                valid_network.join(", ")
            )));
        }

        // Rule: permissions.filesystem valid value
        let valid_fs = ["ro", "rw", "private-tmpfs"];
        if !valid_fs.contains(&self.permissions.filesystem.as_str()) {
            return Err(DescriptorError::Validation(format!(
                "permissions.filesystem '{}' must be one of: {}",
                self.permissions.filesystem,
                valid_fs.join(", ")
            )));
        }

        Ok(())
    }
    // validate:end
}

// ── Validation helpers ────────────────────────────────────────────────────────

// validate_app_id:start
//   purpose: Validate reverse-DNS app id — lowercase alphanumeric, dots, hyphens only.
//   input:  id: &str.
//   output: Result<(), String> — Ok or error with description.
//   sideEffects: none.
pub fn validate_app_id(id: &str) -> Result<(), String> {
    if id.is_empty() || id.len() > 128 {
        return Err(format!("length {} is out of valid range 1..=128", id.len()));
    }
    for ch in id.chars() {
        if !matches!(ch, 'a'..='z' | '0'..='9' | '.' | '-') {
            return Err(format!(
                "invalid character '{ch}' — only lowercase a-z, 0-9, '.', '-' are allowed"
            ));
        }
    }
    // Must contain at least one dot (reverse-DNS)
    if !id.contains('.') {
        return Err("must use reverse-DNS notation (e.g. 'org.bsdos.foot')".to_string());
    }
    Ok(())
}
// validate_app_id:end

// validate_semver:start
//   purpose: Validate that version string matches semver MAJOR.MINOR.PATCH pattern.
//   input:  v: &str — version string.
//   output: Result<(), String>.
//   sideEffects: none.
pub fn validate_semver(v: &str) -> Result<(), String> {
    let parts: Vec<&str> = v.split('.').collect();
    if parts.len() < 2 || parts.len() > 3 {
        return Err(format!(
            "'{v}' is not a valid semver (expected MAJOR.MINOR or MAJOR.MINOR.PATCH)"
        ));
    }
    for part in &parts {
        if part.parse::<u64>().is_err() {
            return Err(format!(
                "'{part}' in version '{v}' is not a non-negative integer"
            ));
        }
    }
    Ok(())
}
// validate_semver:end

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    const MINIMAL_TOML: &str = r#"
[meta]
schema_version = "1.0"
id = "org.bsdos.foot"
version = "1.0.0"
name = "Foot Terminal"
description = "Minimal Wayland terminal"
homepage = ""
license = "MIT"

[compatibility]
bsdos_codename_min = "Squirrel"
freebsd_min = "15.1"
arch = ["aarch64", "amd64"]

[runtime]
type = "jail"
entrypoint = "/usr/local/bin/foot"
needs_wayland = true

[permissions]
network = "none"
filesystem = "ro"
"#;

    #[test]
    // test_parse_minimal:start
    //   purpose: Verify minimal jpk.toml parses without error and round-trips correctly.
    //   input:  MINIMAL_TOML constant.
    //   output: none (asserts).
    //   sideEffects: none.
    fn test_parse_minimal() {
        let desc = JpkDescriptor::from_toml_str(MINIMAL_TOML)
            .expect("should parse minimal toml");
        assert_eq!(desc.meta.id, "org.bsdos.foot");
        assert_eq!(desc.meta.schema_version, "1.0");
        assert_eq!(desc.runtime.entrypoint, "/usr/local/bin/foot");
        assert!(desc.runtime.needs_wayland);
    }
    // test_parse_minimal:end

    #[test]
    // test_validate_ok:start
    //   purpose: Verify that valid descriptor passes validation.
    //   input:  MINIMAL_TOML constant.
    //   output: none (asserts).
    //   sideEffects: none.
    fn test_validate_ok() {
        let desc = JpkDescriptor::from_toml_str(MINIMAL_TOML).expect("should parse");
        desc.validate().expect("should validate cleanly");
    }
    // test_validate_ok:end

    #[test]
    // test_validate_bad_schema_version:start
    //   purpose: Verify that schema_version != "1.0" fails validation.
    //   input:  modified descriptor with schema_version = "2.0".
    //   output: none (asserts Err).
    //   sideEffects: none.
    fn test_validate_bad_schema_version() {
        let mut desc = JpkDescriptor::from_toml_str(MINIMAL_TOML).expect("should parse");
        desc.meta.schema_version = "2.0".to_string();
        assert!(desc.validate().is_err());
    }
    // test_validate_bad_schema_version:end

    #[test]
    // test_validate_bad_id:start
    //   purpose: Verify that invalid app_id (uppercase, no dot) fails validation.
    //   input:  modified descriptor with id = "BadID".
    //   output: none (asserts Err).
    //   sideEffects: none.
    fn test_validate_bad_id() {
        let mut desc = JpkDescriptor::from_toml_str(MINIMAL_TOML).expect("should parse");
        desc.meta.id = "BadID".to_string();
        assert!(desc.validate().is_err());
    }
    // test_validate_bad_id:end

    #[test]
    // test_validate_bad_semver:start
    //   purpose: Verify that non-semver version string fails validation.
    //   input:  modified descriptor with version = "notasemver".
    //   output: none (asserts Err).
    //   sideEffects: none.
    fn test_validate_bad_semver() {
        let mut desc = JpkDescriptor::from_toml_str(MINIMAL_TOML).expect("should parse");
        desc.meta.version = "notasemver".to_string();
        assert!(desc.validate().is_err());
    }
    // test_validate_bad_semver:end

    #[test]
    // test_validate_bad_network:start
    //   purpose: Verify that invalid permissions.network value fails validation.
    //   input:  modified descriptor with network = "all".
    //   output: none (asserts Err).
    //   sideEffects: none.
    fn test_validate_bad_network() {
        let mut desc = JpkDescriptor::from_toml_str(MINIMAL_TOML).expect("should parse");
        desc.permissions.network = "all".to_string();
        assert!(desc.validate().is_err());
    }
    // test_validate_bad_network:end

    #[test]
    // test_toml_roundtrip:start
    //   purpose: Verify descriptor serialises back to TOML and parses to the same value.
    //   input:  MINIMAL_TOML constant.
    //   output: none (asserts).
    //   sideEffects: none.
    fn test_toml_roundtrip() {
        let desc = JpkDescriptor::from_toml_str(MINIMAL_TOML).expect("should parse");
        let toml_str = desc.to_toml_string().expect("should serialise");
        let desc2 = JpkDescriptor::from_toml_str(&toml_str).expect("should re-parse");
        assert_eq!(desc, desc2);
    }
    // test_toml_roundtrip:end

    #[test]
    // test_validate_app_id_valid:start
    //   purpose: Verify validate_app_id accepts valid reverse-DNS identifiers.
    //   input:  various valid id strings.
    //   output: none (asserts Ok).
    //   sideEffects: none.
    fn test_validate_app_id_valid() {
        assert!(validate_app_id("org.bsdos.foot").is_ok());
        assert!(validate_app_id("com.example.my-app").is_ok());
        assert!(validate_app_id("org.bsdos.firefox123").is_ok());
    }
    // test_validate_app_id_valid:end

    #[test]
    // test_validate_app_id_invalid:start
    //   purpose: Verify validate_app_id rejects identifiers with bad characters or format.
    //   input:  various invalid id strings.
    //   output: none (asserts Err).
    //   sideEffects: none.
    fn test_validate_app_id_invalid() {
        assert!(validate_app_id("").is_err());           // empty
        assert!(validate_app_id("NoReverseDns").is_err()); // uppercase + no dot means: uppercase fails first
        assert!(validate_app_id("org_bsdos_foot").is_err()); // underscore not allowed
        assert!(validate_app_id("foot").is_err());        // no dot
    }
    // test_validate_app_id_invalid:end
}
