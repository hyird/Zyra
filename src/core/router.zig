const std = @import("std");
const http = @import("http.zig");

pub const RouteHandler = *const fn (*http.HttpRequest) anyerror!http.HttpResponse;

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

    pub fn init(allocator: std.mem.Allocator) Router {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Router) void {
        for (&self.static_routes) |*routes| routes.deinit(self.allocator);
        for (&self.param_routes) |*routes| routes.deinit(self.allocator);
        self.path_methods.deinit(self.allocator);
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

    pub fn dispatch(self: *const Router, req: *http.HttpRequest) !http.HttpResponse {
        const index = methodIndex(req.method);

        if (self.static_routes[index].get(req.path)) |handler| {
            return handler(req);
        }

        for (self.param_routes[index].items) |entry| {
            if (try matchParamPath(entry.path, req.path, req)) return entry.handler(req);
        }

        if (self.path_methods.contains(req.path) or try self.paramPathExistsForOtherMethod(req)) {
            return http.HttpResponse.methodNotAllowed("GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS");
        }

        return http.HttpResponse.notFound();
    }

    fn paramPathExistsForOtherMethod(self: *const Router, req: *const http.HttpRequest) !bool {
        for (self.param_routes, 0..) |routes, index| {
            if (index == methodIndex(req.method)) continue;
            for (routes.items) |entry| {
                if (try pathShapeMatches(entry.path, req.path)) return true;
            }
        }
        return false;
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

fn pathShapeMatches(pattern_raw: []const u8, path_raw: []const u8) !bool {
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
