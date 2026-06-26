// START_AI_HEADER
// MODULE: bsdos-pkgd/src/error.rs
// PURPOSE: Unified error type for bsdos-pkgd.
// INTENT: Provide a single Result error type that covers I/O, TOML, JSON, and validation.
// DEPENDENCIES: thiserror, descriptor::DescriptorError.
// PUBLIC_API: PkgdError.
// END_AI_HEADER

use thiserror::Error;

use crate::descriptor::DescriptorError;

#[derive(Debug, Error)]
pub enum PkgdError {
    #[error("I/O error: {0}")]
    Io(String),

    #[error("descriptor error: {0}")]
    Descriptor(#[from] DescriptorError),

    #[error("JSON error: {0}")]
    Json(String),

    #[error("archive error: {0}")]
    Archive(String),

    #[error("verification failed: {0}")]
    Verify(String),

    #[error("install error: {0}")]
    Install(String),
}
