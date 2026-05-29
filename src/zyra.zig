//! Zyra：一个 Zig 0.16 + std.Io + zio Web 框架。
//!
//! 公共表面镜像 Hical 的架构：`HttpServer`、`Router`、`MiddlewarePipeline`、
//! 请求/响应类型、基于 zio 的 I/O 适配器，以及请求作用域的 arena 分配。

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
pub const typed_route = @import("core/typed_route.zig");
pub const meta_routes = @import("core/meta_routes.zig");
pub const RouteDef = @import("core/meta_routes.zig").RouteDef;
pub const registerRoutes = @import("core/meta_routes.zig").registerRoutes;
pub const registerGroupRoutes = @import("core/meta_routes.zig").registerGroupRoutes;
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
pub const schema = @import("core/schema.zig");
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
pub const FileSink = @import("core/log.zig").FileSink;
pub const AsyncFileSink = @import("core/log.zig").AsyncFileSink;
pub const LogChannel = @import("core/log.zig").LogChannel;
pub const LogChannelRegistry = @import("core/log.zig").LogChannelRegistry;
pub const LogAdmin = @import("core/log.zig").LogAdmin;
pub const zio_backend = @import("io/zio_backend.zig");

test {
    _ = http;
    _ = Router;
    _ = typed_route;
    _ = meta_routes;
    _ = MiddlewarePipeline;
    _ = HttpServer;
    _ = MemoryPool;
    _ = multipart;
    _ = static_files;
    _ = openapi;
    _ = schema;
    _ = websocket;
    _ = cors;
    _ = session;
    _ = ws_hub;
    _ = log;
    _ = header_map;
}
