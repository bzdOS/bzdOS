// START_AI_HEADER
// MODULE: bsdos-run/src/error.rs
// PURPOSE: Unified error type for bsdos-run.
// INTENT: One thiserror enum that covers all failure modes from ipa/plist/mldr modules.
// DEPENDENCIES: thiserror, std::io.
// PUBLIC_API: RunError.
// END_AI_HEADER

use thiserror::Error;

// RunError:start
//   purpose: Unified error type for all bsdos-run failure paths.
//   input:  none (constructed by ? from sub-modules).
//   output: formatted error message via Display.
//   sideEffects: none.
#[derive(Debug, Error)]
pub enum RunError {
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),

    #[error("IPA error: {0}")]
    Ipa(String),

    #[error("plist error: {0}")]
    Plist(String),

    #[error("mldr error: {0}")]
    Mldr(String),

    #[error("zip error: {0}")]
    Zip(#[from] zip::result::ZipError),
}
// RunError:end
