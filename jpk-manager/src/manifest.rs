// START_AI_HEADER
// MODULE: jpk-manager/src/manifest.rs
// PURPOSE: Manifest data structure for JPK packages.
// INTENT: Define the serializable Manifest struct with app_id, entry point, network, device, and devfs settings.
// DEPENDENCIES: serde.
// PUBLIC_API: Manifest struct, Manifest::validate_id.
// END_AI_HEADER

use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize)]
pub struct Manifest {
    pub id: String,
    pub name: String,
    pub version: String,
    pub entry: String,
    pub network: bool,
    pub devices: Vec<String>,
    pub devfs_ruleset: u32,
}

impl Manifest {
    /// Валидация app_id — только a-z, 0-9, точки, дефисы (защита от shell injection)
    // validate_id:start
//   purpose: Validate app_id format — only lowercase alphanumeric, dots, and hyphens (anti-injection).
//   input:  id: application identifier string.
//   output: Result<(), String> — Ok or error with invalid char.
//   sideEffects: none.
    pub fn validate_id(id: &str) -> Result<(), String> {
        if id.is_empty() || id.len() > 128 {
            return Err("invalid id length".to_string());
        }
        for ch in id.chars() {
            if !matches!(ch, 'a'..='z' | '0'..='9' | '.' | '-') {
                return Err(format!("invalid char in id: {ch}"));
            }
        }
        Ok(())
    }
    // validate_id:end
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn valid_id_accepted() {
        assert!(Manifest::validate_id("com.example.app-01").is_ok());
        assert!(Manifest::validate_id("a").is_ok());
    }

    #[test]
    fn empty_id_rejected() {
        assert!(Manifest::validate_id("").is_err());
    }

    #[test]
    fn uppercase_rejected() {
        let r = Manifest::validate_id("com.Example.App");
        assert!(r.is_err());
        assert!(r.unwrap_err().contains("invalid char"));
    }

    #[test]
    fn id_too_long_rejected() {
        let long = "a".repeat(129);
        assert!(Manifest::validate_id(&long).is_err());
    }

    #[test]
    fn slash_injection_rejected() {
        assert!(Manifest::validate_id("foo/bar").is_err());
    }
}
