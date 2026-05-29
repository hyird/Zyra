const std = @import("std");
const http = @import("http.zig");
const websocket = @import("websocket.zig");

pub const RouteHandler = *const fn (*http.HttpRequest) anyerror!http.HttpResponse;

/// Handler for an upgraded WebSocket connection. Runs the receive/send loop and
/// returns when the connection should be closed.
pub const WsHandler = *const fn (*websocket.WebSocketSession) anyerror!void;

const method_count = @typeInfo(http.HttpMethod).@"enum".fields.len;

const RouteEntry = struct {
    path: []const u8,
    handler: RouteHandler,
};

pub const Router = struct {
    allocator: std.mem.Allocator,
    static_routes: [method_count]std.StringHashMapUnmanaged(RouteHandler) = .{std.StringHashMapUnmanaged(RouteHandler).empty} ** method_count,
    param_routes: [method_count]std.ArrayListUnmanaged(RouteEntry) = .{std.ArrayListUnmanaged(RouteEntry).empty} ** method_count,
    path_methods: std.StringHashMapUnmanaged(u16) = .{},
    owned_paths: std.ArrayListUnmanaged([]const u8) = .empty,
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
    }

    pub fn route(self: *Router, method: http.HttpMethod, path: []const u8, handler: RouteHandler) !void {
        const index = methodIndex(method);
        if (isParamPath(path)) {
            try self.param_routes[index].append(self.allocator, .{ .path = path, .handler = handler });
        } else {
            try self.static_routes[index].put(self.allocator, path, handler);
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

        if (self.static_routes[index].get(req.path)) |handler| {
            return handler(req);
        }

        for (self.param_routes[index].items) |entry| {
            const checkpoint = req.paramCheckpoint();
            if (try matchParamPath(entry.path, req.path, req)) return entry.handler(req);
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

    pub fn route(self: RouteGroup, method: http.HttpMethod, path: []const u8, handler: RouteHandler) !void {
        const joined = try joinPath(self.router.allocator, self.prefix, path);
        errdefer self.router.allocator.free(joined);
        try self.router.route(method, joined, handler);
        try self.router.owned_paths.append(self.router.allocator, joined);
    }

    pub fn get(self: RouteGroup, path: []const u8, handler: RouteHandler) !void {
        try self.route(.get, path, handler);
    }

    pub fn post(self: RouteGroup, path: []const u8, handler: RouteHandler) !void {
        try self.route(.post, path, handler);
    }

    pub fn put(self: RouteGroup, path: []const u8, handler: RouteHandler) !void {
        try self.route(.put, path, handler);
    }

    pub fn patch(self: RouteGroup, path: []const u8, handler: RouteHandler) !void {
        try self.route(.patch, path, handler);
    }

    pub fn delete(self: RouteGroup, path: []const u8, handler: RouteHandler) !void {
        try self.route(.delete, path, handler);
    }

    pub fn del(self: RouteGroup, path: []const u8, handler: RouteHandler) !void {
        try self.delete(path, handler);
    }

    pub fn head(self: RouteGroup, path: []const u8, handler: RouteHandler) !void {
        try self.route(.head, path, handler);
    }

    pub fn options(self: RouteGroup, path: []const u8, handler: RouteHandler) !void {
        try self.route(.options, path, handler);
    }

    pub fn group(self: RouteGroup, sub_prefix: []const u8) !RouteGroup {
        const joined = try joinPath(self.router.allocator, self.prefix, sub_prefix);
        errdefer self.router.allocator.free(joined);
        try self.router.owned_paths.append(self.router.allocator, joined);
        return .{ .router = self.router, .prefix = joined };
    }
};

fn methodIndex(method: http.HttpMethod) usize {
    return @intFromEnum(method);
}

fn methodBit(method: http.HttpMethod) u16 {
    return @as(u16, 1) << @intCast(methodIndex(method));
}

fn isParamPath(path: []const u8) bool {
    return std.mem.indexOfScalar(u8, path, '{') != null;
}

fn matchParamPath(pattern_raw: []const u8, path_raw: []const u8, req: *http.HttpRequest) !bool {
    var pattern = trimLeadingSlash(pattern_raw);
    var path = trimLeadingSlash(path_raw);

    while (pattern.len > 0 or path.len > 0) {
        const p_seg = nextSegment(&pattern);
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
