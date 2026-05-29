//! Comptime route registration ("reflection"-driven routing).
//!
//! Zig has no runtime reflection, but it can introspect types at compile time.
//! This module lets a handler namespace declare its routes once as a `routes`
//! table and register them all in a single call, instead of repeating
//! `router.get(...)` / `router.post(...)` lines.
//!
//! Usage:
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
//! This is the type-safe Zig equivalent of Hical's `HICAL_ROUTES` macro: the
//! `routes` table is validated at compile time and expanded into ordinary
//! `Router.route` calls, so there is zero runtime reflection overhead.

const std = @import("std");
const http = @import("http.zig");
const router_mod = @import("router.zig");

const Router = router_mod.Router;
const RouteGroup = router_mod.RouteGroup;
const RouteHandler = router_mod.RouteHandler;

/// A single declarative route: HTTP method, path pattern, and handler.
pub const RouteDef = struct {
    method: http.HttpMethod,
    path: []const u8,
    handler: RouteHandler,
};

/// Registers every route declared in `Handlers.routes` on `router`.
///
/// `Handlers` must expose a public `routes` declaration that is an array or
/// slice of `RouteDef`. The table is read at compile time; a missing or
/// mis-typed `routes` declaration is a compile error.
pub fn registerRoutes(router: *Router, comptime Handlers: type) !void {
    comptime validateRoutes(Handlers);
    inline for (Handlers.routes) |def| {
        try router.route(def.method, def.path, def.handler);
    }
}

/// Like `registerRoutes`, but registers onto a `RouteGroup` so the group's
/// middleware applies to every declared route.
pub fn registerGroupRoutes(group: *RouteGroup, comptime Handlers: type) !void {
    comptime validateRoutes(Handlers);
    inline for (Handlers.routes) |def| {
        try group.route(def.method, def.path, def.handler);
    }
}

/// Compile-time check that `Handlers` exposes a usable `routes` table.
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
// Tests
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

    // Each declared route dispatches to its handler.
    var req_ping: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/api/ping", .target = "/api/ping" };
    try std.testing.expectEqualStrings("pong", (try router.dispatch(&req_ping)).body);

    var req_echo: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .post, .path = "/api/echo", .target = "/api/echo" };
    try std.testing.expectEqualStrings("echo", (try router.dispatch(&req_echo)).body);

    // The dynamic route captured its path parameter.
    var req_item: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/api/items/42", .target = "/api/items/42" };
    defer req_item.deinit();
    try std.testing.expectEqualStrings("42", (try router.dispatch(&req_item)).body);

    // A method that was not declared yields 405 (path exists for GET only).
    var req_bad: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .delete, .path = "/api/ping", .target = "/api/ping" };
    try std.testing.expectEqual(http.HttpStatus.method_not_allowed, (try router.dispatch(&req_bad)).status);
}
