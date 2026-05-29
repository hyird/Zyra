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

pub const header_map = @import("core/header_map.zig");
pub const HeaderMap = header_map.HeaderMap;

pub const Router = @import("core/router.zig").Router;
pub const RouteGroup = @import("core/router.zig").RouteGroup;
pub const MiddlewarePipeline = @import("core/middleware.zig").MiddlewarePipeline;
pub const Middleware = @import("core/middleware.zig").Middleware;
pub const MiddlewareHandler = @import("core/middleware.zig").MiddlewareHandler;
pub const ContextHandler = @import("core/middleware.zig").ContextHandler;
pub const BeforeHandler = @import("core/middleware.zig").BeforeHandler;
pub const AfterHandler = @import("core/middleware.zig").AfterHandler;
pub const Next = @import("core/middleware.zig").Next;
pub const HttpServer = @import("core/server.zig").HttpServer;
pub const MemoryPool = @import("core/memory_pool.zig").MemoryPool;
pub const multipart = @import("core/multipart.zig");
pub const static_files = @import("core/static_files.zig");
pub const StaticFiles = @import("core/static_files.zig").StaticFiles;
pub const openapi = @import("core/openapi.zig");
pub const OpenApiDocument = @import("core/openapi.zig").OpenApiDocument;
pub const websocket = @import("core/websocket.zig");
pub const cors = @import("core/cors.zig");
pub const Cors = @import("core/cors.zig").Cors;
pub const CorsOptions = @import("core/cors.zig").CorsOptions;
pub const session = @import("core/session.zig");
pub const Session = @import("core/session.zig").Session;
pub const SessionManager = @import("core/session.zig").SessionManager;
pub const SessionMiddleware = @import("core/session.zig").SessionMiddleware;
pub const ws_hub = @import("core/ws_hub.zig");
pub const WsHub = @import("core/ws_hub.zig").WsHub;
pub const log = @import("core/log.zig");
pub const Logger = @import("core/log.zig").Logger;
pub const LogMiddleware = @import("core/log.zig").LogMiddleware;
pub const zio_backend = @import("io/zio_backend.zig");

test {
    _ = http;
    _ = Router;
    _ = MiddlewarePipeline;
    _ = HttpServer;
    _ = MemoryPool;
    _ = multipart;
    _ = static_files;
    _ = openapi;
    _ = websocket;
    _ = cors;
    _ = session;
    _ = ws_hub;
    _ = log;
    _ = header_map;
}
