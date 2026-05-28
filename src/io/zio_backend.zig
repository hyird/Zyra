//! zio-backed adapter layer.
//!
//! The framework's HTTP session code consumes `std.Io.Reader` and
//! `std.Io.Writer` interfaces provided by `zio.net.Stream.reader()` and
//! `zio.net.Stream.writer()`. This keeps parser/router code library-style while
//! the runtime is supplied by zio.

pub const zio = @import("zio");
pub const Stream = zio.net.Stream;
pub const Runtime = zio.Runtime;
pub const Group = zio.Group;
