//! Zyra: a Zig 0.16 + std.Io + zio web framework.
//!
//! The public surface mirrors Hical's architecture: `HttpServer`, `Router`,
//! `MiddlewarePipeline`, request/response types, a zio-backed I/O adapter, and
//! request-scoped arena allocation.

pub const http = @import("core/http.zig");
pub const HttpMethod = http.HttpMethod;
pub const HttpStatus = http.HttpStatus;
pub const Header = http.Header;
pub const HttpRequest = http.HttpRequest;
pub const HttpResponse = http.HttpResponse;

pub const Router = @import("core/router.zig").Router;
pub const RouteGroup = @import("core/router.zig").RouteGroup;
pub const MiddlewarePipeline = @import("core/middleware.zig").MiddlewarePipeline;
pub const HttpServer = @import("core/server.zig").HttpServer;
pub const MemoryPool = @import("core/memory_pool.zig").MemoryPool;
pub const zio_backend = @import("io/zio_backend.zig");

test {
    _ = http;
    _ = Router;
    _ = MiddlewarePipeline;
    _ = HttpServer;
    _ = MemoryPool;
}
