//! wlstream — Wayland stream protocol v1.
//!
//! Wire format for streaming remote Wayland sessions: pixel data,
//! surface commits, cursor events, with LZ4 compression and damage rects.
//!
//! ## Modules
//!
//! - [`protocol`] — damage rect primitives (`Rect`, `clamp_damage`, `merge_damage`)
//! - [`parser`] — decode wire bytes into [`StreamEvent`](parser::StreamEvent) values
//! - [`sender`] — encode [`StreamEvent`](parser::StreamEvent) values into wire bytes
//! - [`compositor`] — state machine that composites RGBA frames from events
//! - [`lz4`] — thin wrapper over `lz4_flex` for compress/decompress

pub mod compositor;
pub mod lz4;
pub mod parser;
pub mod protocol;
pub mod sender;

pub use compositor::Compositor;
pub use parser::{is_v1_protocol, parse_events, StreamEvent};
pub use protocol::Rect;
pub use sender::Encoder;
