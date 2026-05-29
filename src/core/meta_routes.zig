//! 编译期路由注册（“反射”驱动的路由）。
//!
//! Zig 没有运行时反射，但可以在编译期对类型做内省。本模块让一个处理函数
//! 命名空间把自己的路由用一张 `routes` 表声明一次，再用一次调用全部注册，
//! 而不必重复写 `router.get(...)` / `router.post(...)` 这些行。
//!
//! 用法：
//! ```zig
//! const UserApi = struct {
//!     pub const routes = [_]meta_routes.RouteDef{
//!         .{ .method = .get, .path = "/api/users", .handler = listUsers },
//!         .{ .method = .get, .path = "/api/users/{id}", .handler = getUser },
//!         .{ .method = .post, .path = "/api/users", .handler = createUser },
//!     };
//!
//!     fn listUsers(req: *zyra.HttpRequest) !zyra.HttpResponse { ... }
//!     fn getUser(req: *zyra.HttpRequest) !zyra.HttpResponse { ... }
//!     fn createUser(req: *zyra.HttpRequest) !zyra.HttpResponse { ... }
//! };
//!
//! try meta_routes.registerRoutes(router, UserApi);
//! ```
//!
//! 这是 Hical `HICAL_ROUTES` 宏的类型安全 Zig 等价物：`routes` 表在编译期
//! 校验，并被展开成普通的 `Router.route` 调用，因此没有任何运行时反射开销。

const std = @import("std");
const http = @import("http.zig");
const router_mod = @import("router.zig");

const Router = router_mod.Router;
const RouteGroup = router_mod.RouteGroup;
const RouteHandler = router_mod.RouteHandler;

/// 一条声明式路由：HTTP 方法、路径模式、处理函数。
pub const RouteDef = struct {
    method: http.HttpMethod,
    path: []const u8,
    handler: RouteHandler,
};

/// 把 `Handlers.routes` 中声明的每条路由注册到 `router` 上。
///
/// `Handlers` 必须暴露一个公共的 `routes` 声明，且它是 `RouteDef` 的数组
/// 或切片。该表在编译期被读取；缺失或类型不符的 `routes` 声明会触发编译
/// 错误。
pub fn registerRoutes(router: *Router, comptime Handlers: type) !void {
    comptime validateRoutes(Handlers);
    inline for (Handlers.routes) |def| {
        try router.route(def.method, def.path, def.handler);
    }
}

/// 同 `registerRoutes`，但注册到 `RouteGroup` 上，使组的中间件作用于每条
/// 声明的路由。
pub fn registerGroupRoutes(group: *RouteGroup, comptime Handlers: type) !void {
    comptime validateRoutes(Handlers);
    inline for (Handlers.routes) |def| {
        try group.route(def.method, def.path, def.handler);
    }
}

/// 编译期检查：确认 `Handlers` 暴露了一张可用的 `routes` 表。
fn validateRoutes(comptime Handlers: type) void {
    if (!@hasDecl(Handlers, "routes")) {
        @compileError(@typeName(Handlers) ++ " has no public `routes` declaration");
    }
    for (Handlers.routes) |def| {
        if (@TypeOf(def) != RouteDef) {
            @compileError(@typeName(Handlers) ++ ".routes must be an array of RouteDef");
        }
    }
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const TestApi = struct {
    pub const routes = [_]RouteDef{
        .{ .method = .get, .path = "/api/ping", .handler = ping },
        .{ .method = .post, .path = "/api/echo", .handler = echo },
        .{ .method = .get, .path = "/api/items/{id}", .handler = item },
    };

    fn ping(_: *http.HttpRequest) anyerror!http.HttpResponse {
        return http.HttpResponse.text("pong");
    }
    fn echo(_: *http.HttpRequest) anyerror!http.HttpResponse {
        return http.HttpResponse.text("echo");
    }
    fn item(req: *http.HttpRequest) anyerror!http.HttpResponse {
        return http.HttpResponse.text(req.param("id") orelse "none");
    }
};

test "registerRoutes registers every declared route" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    try registerRoutes(&router, TestApi);

    // 每条声明的路由都能分派到各自的处理函数。
    var req_ping: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/api/ping", .target = "/api/ping" };
    try std.testing.expectEqualStrings("pong", (try router.dispatch(&req_ping)).body);

    var req_echo: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .post, .path = "/api/echo", .target = "/api/echo" };
    try std.testing.expectEqualStrings("echo", (try router.dispatch(&req_echo)).body);

    // 动态路由捕获到了它的路径参数。
    var req_item: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/api/items/42", .target = "/api/items/42" };
    defer req_item.deinit();
    try std.testing.expectEqualStrings("42", (try router.dispatch(&req_item)).body);

    // 未声明的方法返回 405（该路径只为 GET 存在）。
    var req_bad: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .delete, .path = "/api/ping", .target = "/api/ping" };
    try std.testing.expectEqual(http.HttpStatus.method_not_allowed, (try router.dispatch(&req_bad)).status);
}
