const std = @import("std");
const http = @import("http.zig");
const websocket = @import("websocket.zig");

pub const RouteHandler = *const fn (*http.HttpRequest) anyerror!http.HttpResponse;

/// A synchronous "before" hook for a route group. Returning a response
/// short-circuits the route (and runs the already-entered groups' `after`
/// hooks); returning `null` continues to the next group hook or the handler.
pub const GroupBeforeHandler = *const fn (*http.HttpRequest) anyerror!?http.HttpResponse;

/// A synchronous "after" hook for a route group. Runs after the handler (or a
/// short-circuiting `before`) produces a response and may mutate it.
pub const GroupAfterHandler = *const fn (*http.HttpRequest, *http.HttpResponse) anyerror!void;

/// One group-level middleware: an optional before hook and an optional after
/// hook. Applied only to routes registered through the owning `RouteGroup`.
pub const GroupMiddleware = struct {
    before: ?GroupBeforeHandler = null,
    after: ?GroupAfterHandler = null,
};

/// Handler for an upgraded WebSocket connection. Runs the receive/send loop and
/// returns when the connection should be closed.
pub const WsHandler = *const fn (*websocket.WebSocketSession) anyerror!void;

const method_count = @typeInfo(http.HttpMethod).@"enum".fields.len;

/// A stored route: the user's handler plus the (possibly empty) chain of
/// group-level middleware that wraps it. The middleware slice is borrowed and
/// must outlive the router (group middleware chains are owned by the router's
/// `owned_chains` arena-like list).
pub const RouteEndpoint = struct {
    handler: RouteHandler,
    middleware: []const GroupMiddleware = &.{},

    /// Runs the group middleware chain (before hooks in order, after hooks in
    /// reverse) around the handler. A short-circuiting before hook still runs
    /// the after hooks of the groups already entered.
    pub fn invoke(self: RouteEndpoint, req: *http.HttpRequest) anyerror!http.HttpResponse {
        var entered: usize = 0;
        for (self.middleware) |mw| {
            entered += 1;
            if (mw.before) |before| {
                if (try before(req)) |short| {
                    var resp = short;
                    try runAfter(self.middleware[0..entered], req, &resp);
                    return resp;
                }
            }
        }
        var resp = try self.handler(req);
        try runAfter(self.middleware[0..entered], req, &resp);
        return resp;
    }

    fn runAfter(chain: []const GroupMiddleware, req: *http.HttpRequest, resp: *http.HttpResponse) anyerror!void {
        var i = chain.len;
        while (i > 0) {
            i -= 1;
            if (chain[i].after) |after| try after(req, resp);
        }
    }
};

const RouteEntry = struct {
    path: []const u8,
    endpoint: RouteEndpoint,
};

pub const Router = struct {
    allocator: std.mem.Allocator,
    static_routes: [method_count]std.StringHashMapUnmanaged(RouteEndpoint) = .{std.StringHashMapUnmanaged(RouteEndpoint).empty} ** method_count,
    param_routes: [method_count]std.ArrayListUnmanaged(RouteEntry) = .{std.ArrayListUnmanaged(RouteEntry).empty} ** method_count,
    path_methods: std.StringHashMapUnmanaged(u16) = .{},
    owned_paths: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Owns the merged group-middleware chains created by `RouteGroup`s, freed
    /// in `deinit`. Endpoints borrow slices from these.
    owned_chains: std.ArrayListUnmanaged([]GroupMiddleware) = .empty,
    ws_routes: std.StringHashMapUnmanaged(WsHandler) = .{},

    pub fn init(allocator: std.mem.Allocator) Router {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Router) void {
        for (&self.static_routes) |*routes| routes.deinit(self.allocator);
        for (&self.param_routes) |*routes| routes.deinit(self.allocator);
        self.path_methods.deinit(self.allocator);
        self.ws_routes.deinit(self.allocator);
        for (self.owned_paths.items) |path| self.allocator.free(path);
        self.owned_paths.deinit(self.allocator);
        for (self.owned_chains.items) |chain| self.allocator.free(chain);
        self.owned_chains.deinit(self.allocator);
    }

    pub fn route(self: *Router, method: http.HttpMethod, path: []const u8, handler: RouteHandler) !void {
        try self.routeEndpoint(method, path, .{ .handler = handler });
    }

    /// Registers a route carrying an explicit endpoint (handler + group
    /// middleware chain). Used by `RouteGroup` to attach group-scoped
    /// middleware; most callers use `route`/the verb helpers instead.
    pub fn routeEndpoint(self: *Router, method: http.HttpMethod, path: []const u8, endpoint: RouteEndpoint) !void {
        const index = methodIndex(method);
        if (isParamPath(path)) {
            try self.param_routes[index].append(self.allocator, .{ .path = path, .endpoint = endpoint });
        } else {
            try self.static_routes[index].put(self.allocator, path, endpoint);
        }

        const bit = methodBit(method);
        const result = try self.path_methods.getOrPut(self.allocator, path);
        result.value_ptr.* = if (result.found_existing) result.value_ptr.* | bit else bit;
    }

    pub fn get(self: *Router, path: []const u8, handler: RouteHandler) !void {
        try self.route(.get, path, handler);
    }

    pub fn post(self: *Router, path: []const u8, handler: RouteHandler) !void {
        try self.route(.post, path, handler);
    }

    pub fn put(self: *Router, path: []const u8, handler: RouteHandler) !void {
        try self.route(.put, path, handler);
    }

    pub fn patch(self: *Router, path: []const u8, handler: RouteHandler) !void {
        try self.route(.patch, path, handler);
    }

    pub fn delete(self: *Router, path: []const u8, handler: RouteHandler) !void {
        try self.route(.delete, path, handler);
    }

    pub fn del(self: *Router, path: []const u8, handler: RouteHandler) !void {
        try self.delete(path, handler);
    }

    pub fn head(self: *Router, path: []const u8, handler: RouteHandler) !void {
        try self.route(.head, path, handler);
    }

    pub fn options(self: *Router, path: []const u8, handler: RouteHandler) !void {
        try self.route(.options, path, handler);
    }

    /// Registers a WebSocket handler for an exact path. The connection is
    /// upgraded automatically when a client sends a WebSocket upgrade request
    /// for this path.
    pub fn ws(self: *Router, path: []const u8, handler: WsHandler) !void {
        try self.ws_routes.put(self.allocator, path, handler);
    }

    /// Looks up the WebSocket handler registered for an exact path, if any.
    pub fn wsHandler(self: *const Router, path: []const u8) ?WsHandler {
        return self.ws_routes.get(path);
    }

    /// Calls `callback(ctx, method, path)` for every registered HTTP route
    /// (static and parameterized), in no particular order. Used for
    /// introspection such as OpenAPI document generation.
    pub fn forEachRoute(
        self: *const Router,
        ctx: anytype,
        comptime callback: fn (@TypeOf(ctx), http.HttpMethod, []const u8) anyerror!void,
    ) anyerror!void {
        for (self.static_routes, 0..) |routes, index| {
            const method: http.HttpMethod = @enumFromInt(index);
            var it = routes.iterator();
            while (it.next()) |entry| {
                try callback(ctx, method, entry.key_ptr.*);
            }
        }
        for (self.param_routes, 0..) |routes, index| {
            const method: http.HttpMethod = @enumFromInt(index);
            for (routes.items) |entry| {
                try callback(ctx, method, entry.path);
            }
        }
    }

    pub fn routeCount(self: *const Router) usize {
        var count: usize = 0;
        for (self.static_routes) |routes| count += routes.count();
        for (self.param_routes) |routes| count += routes.items.len;
        return count;
    }

    pub fn group(self: *Router, prefix: []const u8) RouteGroup {
        return .{ .router = self, .prefix = prefix };
    }

    pub fn dispatch(self: *const Router, req: *http.HttpRequest) !http.HttpResponse {
        const index = methodIndex(req.method);

        if (self.static_routes[index].get(req.path)) |endpoint| {
            return endpoint.invoke(req);
        }

        for (self.param_routes[index].items) |entry| {
            const checkpoint = req.paramCheckpoint();
            if (try matchParamPath(entry.path, req.path, req)) return entry.endpoint.invoke(req);
            req.rollbackParams(checkpoint);
        }

        if (self.allowedMethods(req)) |allow| {
            return http.HttpResponse.methodNotAllowed(allow);
        }

        return http.HttpResponse.notFound();
    }

    fn allowedMethods(self: *const Router, req: *const http.HttpRequest) ?[]const u8 {
        var bits: u16 = self.path_methods.get(req.path) orelse 0;

        for (self.param_routes, 0..) |routes, index| {
            for (routes.items) |entry| {
                if (pathShapeMatches(entry.path, req.path)) bits |= @as(u16, 1) << @intCast(index);
            }
        }

        bits &= ~methodBit(req.method);
        if (bits == 0) return null;
        return allowHeader(bits);
    }
};

fn allowHeader(bits: u16) []const u8 {
    return switch (bits) {
        methodBit(.get) => "GET",
        methodBit(.post) => "POST",
        methodBit(.put) => "PUT",
        methodBit(.delete) => "DELETE",
        methodBit(.patch) => "PATCH",
        methodBit(.head) => "HEAD",
        methodBit(.options) => "OPTIONS",
        methodBit(.get) | methodBit(.post) => "GET, POST",
        methodBit(.get) | methodBit(.head) => "GET, HEAD",
        else => "GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS",
    };
}

pub const RouteGroup = struct {
    router: *Router,
    prefix: []const u8,
    /// Group-level middleware accumulated via `use`/`useBeforeAfter`, applied to
    /// every route registered through this group (and inherited by subgroups).
    /// Backed by the router's allocator; the storage is freed with the router.
    chain: std.ArrayListUnmanaged(GroupMiddleware) = .empty,

    /// Adds a full before/after group middleware. Affects only routes
    /// registered through this group after the call. Returns the group for
    /// chaining.
    pub fn use(self: *RouteGroup, middleware: GroupMiddleware) !*RouteGroup {
        try self.chain.append(self.router.allocator, middleware);
        return self;
    }

    /// Adds a before hook (and optional after hook) as group middleware.
    pub fn useBeforeAfter(
        self: *RouteGroup,
        before: ?GroupBeforeHandler,
        after: ?GroupAfterHandler,
    ) !*RouteGroup {
        return self.use(.{ .before = before, .after = after });
    }

    /// Snapshots the current middleware chain into router-owned storage so the
    /// endpoint can borrow a stable slice independent of later `use` calls.
    fn snapshotChain(self: *RouteGroup) ![]const GroupMiddleware {
        if (self.chain.items.len == 0) return &.{};
        const copy = try self.router.allocator.dupe(GroupMiddleware, self.chain.items);
        errdefer self.router.allocator.free(copy);
        try self.router.owned_chains.append(self.router.allocator, copy);
        return copy;
    }

    pub fn route(self: *RouteGroup, method: http.HttpMethod, path: []const u8, handler: RouteHandler) !void {
        const joined = try joinPath(self.router.allocator, self.prefix, path);
        errdefer self.router.allocator.free(joined);
        const middleware = try self.snapshotChain();
        try self.router.routeEndpoint(method, joined, .{ .handler = handler, .middleware = middleware });
        try self.router.owned_paths.append(self.router.allocator, joined);
    }

    pub fn get(self: *RouteGroup, path: []const u8, handler: RouteHandler) !void {
        try self.route(.get, path, handler);
    }

    pub fn post(self: *RouteGroup, path: []const u8, handler: RouteHandler) !void {
        try self.route(.post, path, handler);
    }

    pub fn put(self: *RouteGroup, path: []const u8, handler: RouteHandler) !void {
        try self.route(.put, path, handler);
    }

    pub fn patch(self: *RouteGroup, path: []const u8, handler: RouteHandler) !void {
        try self.route(.patch, path, handler);
    }

    pub fn delete(self: *RouteGroup, path: []const u8, handler: RouteHandler) !void {
        try self.route(.delete, path, handler);
    }

    pub fn del(self: *RouteGroup, path: []const u8, handler: RouteHandler) !void {
        try self.delete(path, handler);
    }

    pub fn head(self: *RouteGroup, path: []const u8, handler: RouteHandler) !void {
        try self.route(.head, path, handler);
    }

    pub fn options(self: *RouteGroup, path: []const u8, handler: RouteHandler) !void {
        try self.route(.options, path, handler);
    }

    /// Creates a nested subgroup. The subgroup inherits this group's prefix and
    /// a copy of its current middleware chain; further `use` calls on either
    /// group are independent thereafter.
    pub fn group(self: *RouteGroup, sub_prefix: []const u8) !RouteGroup {
        const joined = try joinPath(self.router.allocator, self.prefix, sub_prefix);
        errdefer self.router.allocator.free(joined);
        try self.router.owned_paths.append(self.router.allocator, joined);
        var child: std.ArrayListUnmanaged(GroupMiddleware) = .empty;
        if (self.chain.items.len > 0) {
            try child.appendSlice(self.router.allocator, self.chain.items);
        }
        return .{ .router = self.router, .prefix = joined, .chain = child };
    }

    pub fn deinit(self: *RouteGroup) void {
        self.chain.deinit(self.router.allocator);
    }
};

fn methodIndex(method: http.HttpMethod) usize {
    return @intFromEnum(method);
}

fn methodBit(method: http.HttpMethod) u16 {
    return @as(u16, 1) << @intCast(methodIndex(method));
}

fn isParamPath(path: []const u8) bool {
    return std.mem.indexOfScalar(u8, path, '{') != null or
        std.mem.indexOfScalar(u8, path, '*') != null;
}

/// True for a trailing catch-all segment: `*`, `*name`, or `{*name}`.
/// A catch-all captures the entire remainder of the request path (including any
/// embedded slashes) and must be the last segment of the pattern.
fn isWildcardSegment(segment: []const u8) bool {
    if (segment.len == 0) return false;
    if (segment[0] == '*') return true; // `*` or `*name`
    if (isParamSegment(segment) and segment[1] == '*') return true; // `{*name}`
    return false;
}

/// Returns the capture name for a wildcard segment (may be empty for a bare
/// `*`). Assumes `isWildcardSegment(segment)` is true.
fn wildcardName(segment: []const u8) []const u8 {
    if (segment[0] == '*') return segment[1..]; // `*name` -> `name`, `*` -> ``
    return segment[2 .. segment.len - 1]; // `{*name}` -> `name`
}

fn matchParamPath(pattern_raw: []const u8, path_raw: []const u8, req: *http.HttpRequest) !bool {
    var pattern = trimLeadingSlash(pattern_raw);
    var path = trimLeadingSlash(path_raw);

    while (pattern.len > 0 or path.len > 0) {
        const remainder = path;
        const p_seg = nextSegment(&pattern);
        if (p_seg) |p| {
            if (isWildcardSegment(p)) {
                // Catch-all: bind the entire remaining path and finish. The
                // wildcard must be the final pattern segment.
                if (pattern.len != 0) return false;
                const name = wildcardName(p);
                if (name.len > 0) try req.setParam(name, remainder);
                return true;
            }
        }
        const r_seg = nextSegment(&path);
        if (p_seg == null or r_seg == null) return false;

        const p = p_seg.?;
        const r = r_seg.?;
        if (isParamSegment(p)) {
            try req.setParam(p[1 .. p.len - 1], r);
        } else if (!std.mem.eql(u8, p, r)) {
            return false;
        }
    }
    return true;
}

fn pathShapeMatches(pattern_raw: []const u8, path_raw: []const u8) bool {
    var pattern = trimLeadingSlash(pattern_raw);
    var path = trimLeadingSlash(path_raw);

    while (pattern.len > 0 or path.len > 0) {
        const p_seg = nextSegment(&pattern);
        if (p_seg) |p| {
            if (isWildcardSegment(p)) return pattern.len == 0;
        }
        const r_seg = nextSegment(&path);
        if (p_seg == null or r_seg == null) return false;
        const p = p_seg.?;
        const r = r_seg.?;
        if (!isParamSegment(p) and !std.mem.eql(u8, p, r)) return false;
    }
    return true;
}

fn isParamSegment(segment: []const u8) bool {
    return segment.len >= 3 and segment[0] == '{' and segment[segment.len - 1] == '}';
}

fn trimLeadingSlash(value: []const u8) []const u8 {
    return if (value.len > 0 and value[0] == '/') value[1..] else value;
}

fn nextSegment(value: *[]const u8) ?[]const u8 {
    if (value.len == 0) return null;
    const slash = std.mem.indexOfScalar(u8, value.*, '/') orelse value.len;
    const seg = value.*[0..slash];
    value.* = if (slash == value.len) "" else value.*[slash + 1 ..];
    return seg;
}

fn joinPath(allocator: std.mem.Allocator, prefix: []const u8, path: []const u8) ![]const u8 {
    if (prefix.len == 0 or std.mem.eql(u8, prefix, "/")) return try allocator.dupe(u8, path);
    if (path.len == 0 or std.mem.eql(u8, path, "/")) return try allocator.dupe(u8, prefix);
    if (prefix[prefix.len - 1] == '/' and path[0] == '/') return try std.mem.concat(allocator, u8, &.{ prefix[0 .. prefix.len - 1], path });
    if (prefix[prefix.len - 1] != '/' and path[0] != '/') return try std.mem.concat(allocator, u8, &.{ prefix, "/", path });
    return try std.mem.concat(allocator, u8, &.{ prefix, path });
}

test "parameter route matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var req: http.HttpRequest = .{ .allocator = arena.allocator(), .method = .get, .path = "/users/42", .target = "/users/42" };
    try std.testing.expect(try matchParamPath("/users/{id}", req.path, &req));
    try std.testing.expectEqualStrings("42", req.param("id").?);
}

test "static route dispatches through map" {
    const handler = struct {
        fn ok(_: *http.HttpRequest) !http.HttpResponse {
            return http.HttpResponse.text("ok");
        }
    }.ok;

    var router = Router.init(std.testing.allocator);
    defer router.deinit();
    try router.get("/", handler);

    var req: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/", .target = "/" };
    const res = try router.dispatch(&req);
    try std.testing.expectEqual(http.HttpStatus.ok, res.status);
    try std.testing.expectEqualStrings("ok", res.body);
}

test "route group prefixes routes" {
    const handler = struct {
        fn ok(_: *http.HttpRequest) !http.HttpResponse {
            return http.HttpResponse.text("group");
        }
    }.ok;

    var router = Router.init(std.testing.allocator);
    defer router.deinit();
    var api = router.group("/api/v1");
    try api.get("/users", handler);

    var req: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/api/v1/users", .target = "/api/v1/users" };
    const res = try router.dispatch(&req);
    try std.testing.expectEqual(http.HttpStatus.ok, res.status);
    try std.testing.expectEqualStrings("group", res.body);
    try std.testing.expectEqual(@as(usize, 1), router.routeCount());
}

fn textHandler(comptime body: []const u8) RouteHandler {
    return (struct {
        pub const msg = body;

        fn handler(_: *http.HttpRequest) !http.HttpResponse {
            return http.HttpResponse.text(msg);
        }
    }).handler;
}

test "router route and verb helpers register static routes" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    try router.route(.get, "/route", textHandler("route"));
    try router.get("/get", textHandler("get"));
    try router.post("/post", textHandler("post"));
    try router.put("/put", textHandler("put"));
    try router.patch("/patch", textHandler("patch"));
    try router.delete("/delete", textHandler("delete"));
    try router.del("/del", textHandler("del"));
    try router.head("/head", textHandler("head"));
    try router.options("/options", textHandler("options"));

    try std.testing.expectEqual(@as(usize, 9), router.routeCount());
}

test "dispatch handles success 404 and 405" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    try router.get("/ok", textHandler("ok"));
    try router.post("/same", textHandler("post"));

    var req_ok: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/ok", .target = "/ok" };
    const res_ok = try router.dispatch(&req_ok);
    try std.testing.expectEqual(http.HttpStatus.ok, res_ok.status);
    try std.testing.expectEqualStrings("ok", res_ok.body);

    var req_nf: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/missing", .target = "/missing" };
    const res_nf = try router.dispatch(&req_nf);
    try std.testing.expectEqual(http.HttpStatus.not_found, res_nf.status);

    var req_ma: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/same", .target = "/same" };
    const res_ma = try router.dispatch(&req_ma);
    try std.testing.expectEqual(http.HttpStatus.method_not_allowed, res_ma.status);
    try std.testing.expectEqualStrings("POST", res_ma.header("allow").?);
}

test "dispatch matches parameter routes and rolls back failed params" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    try router.get("/users/{id}", struct {
        fn handler(req: *http.HttpRequest) !http.HttpResponse {
            try std.testing.expectEqualStrings("42", req.param("id").?);
            return http.HttpResponse.text("user");
        }
    }.handler);

    try router.get("/items/{first}/x", textHandler("nope"));
    try router.get("/items/{second}/b", struct {
        fn handler(req: *http.HttpRequest) !http.HttpResponse {
            try std.testing.expect(req.param("first") == null);
            try std.testing.expectEqualStrings("1", req.param("second").?);
            return http.HttpResponse.text("item");
        }
    }.handler);

    var req_user: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/users/42", .target = "/users/42" };
    const res_user = try router.dispatch(&req_user);
    try std.testing.expectEqualStrings("user", res_user.body);

    var req_item: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/items/1/b", .target = "/items/1/b" };
    const res_item = try router.dispatch(&req_item);
    try std.testing.expectEqualStrings("item", res_item.body);
}

test "route group helpers and nested groups join paths" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    var api = router.group("/api/");
    try api.route(.get, "/v1", textHandler("r"));
    try api.get("users", textHandler("g"));
    try api.post("/users", textHandler("p"));
    try api.put("users/1", textHandler("u"));
    try api.patch("/users/2/", textHandler("pa"));
    try api.delete("/users/3", textHandler("d"));
    try api.del("/users/4", textHandler("dl"));
    try api.head("/users/5", textHandler("h"));
    try api.options("/users/6", textHandler("o"));

    var v2 = try api.group("v2/");
    try v2.get("/nested", textHandler("nested"));

    var req: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/api/v2/nested", .target = "/api/v2/nested" };
    const res = try router.dispatch(&req);
    try std.testing.expectEqualStrings("nested", res.body);
    try std.testing.expectEqual(@as(usize, 10), router.routeCount());
}

test "route group path joining handles slash edge cases" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    var root = router.group("/");
    try root.get("/root", textHandler("root"));

    var plain = router.group("api");
    try plain.get("users", textHandler("users"));

    var trailing = router.group("/admin/");
    try trailing.get("/panel/", textHandler("panel"));

    var req1: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/root", .target = "/root" };
    try std.testing.expectEqualStrings("root", (try router.dispatch(&req1)).body);

    var req2: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "api/users", .target = "api/users" };
    try std.testing.expectEqualStrings("users", (try router.dispatch(&req2)).body);

    var req3: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/admin/panel/", .target = "/admin/panel/" };
    try std.testing.expectEqualStrings("panel", (try router.dispatch(&req3)).body);
}

test "ws handler registration and lookup" {
    const handler = struct {
        fn run(_: *websocket.WebSocketSession) anyerror!void {}
    }.run;

    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    try std.testing.expect(router.wsHandler("/chat") == null);
    try router.ws("/chat", handler);
    try std.testing.expect(router.wsHandler("/chat") != null);
    try std.testing.expect(router.wsHandler("/other") == null);
    // ws routes are independent of HTTP route count.
    try std.testing.expectEqual(@as(usize, 0), router.routeCount());
}

test "named catch-all wildcard captures the remaining path" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    try router.get("/files/{*path}", struct {
        fn handler(req: *http.HttpRequest) !http.HttpResponse {
            return http.HttpResponse.text(req.param("path").?);
        }
    }.handler);

    var req: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/files/a/b/c.txt", .target = "/files/a/b/c.txt" };
    const res = try router.dispatch(&req);
    try std.testing.expectEqual(http.HttpStatus.ok, res.status);
    try std.testing.expectEqualStrings("a/b/c.txt", res.body);
}

test "star-prefixed and bare wildcard segments" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    try router.get("/assets/*rest", struct {
        fn handler(req: *http.HttpRequest) !http.HttpResponse {
            return http.HttpResponse.text(req.param("rest").?);
        }
    }.handler);
    try router.get("/catch/*", textHandler("caught"));

    var req1: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/assets/css/app.css", .target = "/assets/css/app.css" };
    try std.testing.expectEqualStrings("css/app.css", (try router.dispatch(&req1)).body);

    // Bare wildcard matches but captures nothing.
    var req2: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/catch/anything/here", .target = "/catch/anything/here" };
    try std.testing.expectEqualStrings("caught", (try router.dispatch(&req2)).body);
}

test "wildcard combines with leading fixed and param segments" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    try router.get("/u/{id}/files/{*path}", struct {
        fn handler(req: *http.HttpRequest) !http.HttpResponse {
            try std.testing.expectEqualStrings("7", req.param("id").?);
            return http.HttpResponse.text(req.param("path").?);
        }
    }.handler);

    var req: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/u/7/files/deep/nested.bin", .target = "/u/7/files/deep/nested.bin" };
    try std.testing.expectEqualStrings("deep/nested.bin", (try router.dispatch(&req)).body);

    // Non-matching prefix still 404s.
    var req_nf: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/u/7/other/x", .target = "/u/7/other/x" };
    try std.testing.expectEqual(http.HttpStatus.not_found, (try router.dispatch(&req_nf)).status);
}

const GroupTrace = struct {
    var buf: [16]u8 = undefined;
    var len: usize = 0;
    fn reset() void {
        len = 0;
    }
    fn push(c: u8) void {
        buf[len] = c;
        len += 1;
    }
    fn slice() []const u8 {
        return buf[0..len];
    }
};

test "group middleware wraps only group routes (before/after order)" {
    GroupTrace.reset();
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    const hooks = struct {
        fn before(_: *http.HttpRequest) anyerror!?http.HttpResponse {
            GroupTrace.push('b');
            return null;
        }
        fn after(_: *http.HttpRequest, _: *http.HttpResponse) anyerror!void {
            GroupTrace.push('a');
        }
    };

    var api = router.group("/api");
    defer api.deinit();
    _ = try api.useBeforeAfter(hooks.before, hooks.after);
    try api.get("/users", textHandler("users"));

    // A route outside the group: no group middleware runs.
    try router.get("/public", textHandler("public"));

    // Group route: before -> handler -> after.
    var req_api: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/api/users", .target = "/api/users" };
    try std.testing.expectEqualStrings("users", (try router.dispatch(&req_api)).body);
    try std.testing.expectEqualStrings("ba", GroupTrace.slice());

    // Non-group route: trace unchanged.
    GroupTrace.reset();
    var req_pub: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/public", .target = "/public" };
    try std.testing.expectEqualStrings("public", (try router.dispatch(&req_pub)).body);
    try std.testing.expectEqualStrings("", GroupTrace.slice());
}

test "group middleware before can short-circuit and still runs after" {
    GroupTrace.reset();
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    const hooks = struct {
        fn before(_: *http.HttpRequest) anyerror!?http.HttpResponse {
            GroupTrace.push('b');
            return http.HttpResponse.text("blocked");
        }
        fn after(_: *http.HttpRequest, resp: *http.HttpResponse) anyerror!void {
            GroupTrace.push('a');
            try resp.setHeader("x-after", "1");
        }
    };

    var api = router.group("/api");
    defer api.deinit();
    _ = try api.useBeforeAfter(hooks.before, hooks.after);
    try api.get("/x", textHandler("never"));

    var req: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/api/x", .target = "/api/x" };
    const res = try router.dispatch(&req);
    try std.testing.expectEqualStrings("blocked", res.body);
    try std.testing.expectEqualStrings("1", res.header("x-after").?);
    try std.testing.expectEqualStrings("ba", GroupTrace.slice());
}

test "nested group inherits parent middleware and adds its own" {
    GroupTrace.reset();
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    const hooks = struct {
        fn outerBefore(_: *http.HttpRequest) anyerror!?http.HttpResponse {
            GroupTrace.push('1');
            return null;
        }
        fn outerAfter(_: *http.HttpRequest, _: *http.HttpResponse) anyerror!void {
            GroupTrace.push('A');
        }
        fn innerBefore(_: *http.HttpRequest) anyerror!?http.HttpResponse {
            GroupTrace.push('2');
            return null;
        }
        fn innerAfter(_: *http.HttpRequest, _: *http.HttpResponse) anyerror!void {
            GroupTrace.push('B');
        }
    };

    var api = router.group("/api");
    defer api.deinit();
    _ = try api.useBeforeAfter(hooks.outerBefore, hooks.outerAfter);

    var admin = try api.group("/admin");
    defer admin.deinit();
    _ = try admin.useBeforeAfter(hooks.innerBefore, hooks.innerAfter);
    try admin.get("/stats", textHandler("stats"));

    // Outer-only route is unaffected by the inner middleware.
    try api.get("/ping", textHandler("ping"));

    // Nested route: outer-before, inner-before, handler, inner-after, outer-after.
    var req: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/api/admin/stats", .target = "/api/admin/stats" };
    try std.testing.expectEqualStrings("stats", (try router.dispatch(&req)).body);
    try std.testing.expectEqualStrings("12BA", GroupTrace.slice());

    GroupTrace.reset();
    var req_ping: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/api/ping", .target = "/api/ping" };
    try std.testing.expectEqualStrings("ping", (try router.dispatch(&req_ping)).body);
    try std.testing.expectEqualStrings("1A", GroupTrace.slice());
}
