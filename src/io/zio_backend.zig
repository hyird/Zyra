//! 基于 zio 的适配层。
//!
//! 框架仅使用 zio 创建一个 `std.Io` 实现。HTTP 代码消费 `std.Io.net`、
//! `std.Io.Reader` 和 `std.Io.Writer`，而不是直接调用 zio 网络 API。

pub const zio = @import("zio");
pub const Runtime = zio.Runtime;
