//! zio-backed adapter layer.
//!
//! The framework uses zio only to create a `std.Io` implementation. HTTP code
//! consumes `std.Io.net`, `std.Io.Reader`, and `std.Io.Writer` instead of
//! calling zio networking APIs directly.

pub const zio = @import("zio");
pub const Runtime = zio.Runtime;
