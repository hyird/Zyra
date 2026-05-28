const std = @import("std");
const http = @import("http.zig");

pub const RouteHandler = *const fn (*http.HttpRequest) anyerror!http.HttpResponse;

const RouteEntry = struct {
    method: http.HttpMethod,
    path: []const u8,
    handler: RouteHandler,
    is_param: bool,
};

pub const Router = struct {
    allocator: std.mem.Allocator,
    routes: std.ArrayListUnmanaged(RouteEntry) = .empty,

    pub fn init(allocator: std.mem.Allocator) Router {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Router) void {
        self.routes.deinit(self.allocator);
    }

    pub fn route(self: *Router, method: http.HttpMethod, path: []const u8, handler: RouteHandler) !void {
        try self.routes.append(self.allocator, .{
            .method = method,
            .path = path,
            .handler = handler,
            .is_param = std.mem.indexOfScalar(u8, path, '{') != null,
        });
    }

    pub fn get(self: *Router, path: []const u8, handler: RouteHandler) !void {
        try self.route(.get, path, handler);
    }

    pub fn post(self: *Router, path: []const u8, handler: RouteHandler) !void {
        try self.route(.post, path, handler);
    }

    pub fn dispatch(self: *const Router, req: *http.HttpRequest) !http.HttpResponse {
        var method_allowed = false;

        for (self.routes.items) |entry| {
            if (entry.method != req.method) continue;
            if (!entry.is_param and std.mem.eql(u8, entry.path, req.path)) {
                return entry.handler(req);
            }
            if (entry.is_param and try matchParamPath(req.allocator, entry.path, req.path, req)) {
                return entry.handler(req);
            }
        }

        for (self.routes.items) |entry| {
            if (entry.method == req.method) continue;
            if ((!entry.is_param and std.mem.eql(u8, entry.path, req.path)) or
                (entry.is_param and try pathShapeMatches(entry.path, req.path)))
            {
                method_allowed = true;
                break;
            }
        }

        return if (method_allowed) http.HttpResponse.methodNotAllowed("GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS") else http.HttpResponse.notFound();
    }
};

fn matchParamPath(allocator: std.mem.Allocator, pattern_raw: []const u8, path_raw: []const u8, req: *http.HttpRequest) !bool {
    var pattern = trimLeadingSlash(pattern_raw);
    var path = trimLeadingSlash(path_raw);

    while (pattern.len > 0 or path.len > 0) {
        const p_seg = nextSegment(&pattern);
        const r_seg = nextSegment(&path);
        if (p_seg == null or r_seg == null) return false;

        const p = p_seg.?;
        const r = r_seg.?;
        if (p.len >= 3 and p[0] == '{' and p[p.len - 1] == '}') {
            const name = try allocator.dupe(u8, p[1 .. p.len - 1]);
            const value = try allocator.dupe(u8, r);
            try req.setParam(name, value);
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
        if (!(p.len >= 3 and p[0] == '{' and p[p.len - 1] == '}') and !std.mem.eql(u8, p, r)) return false;
    }
    return true;
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
    try std.testing.expect(try matchParamPath(arena.allocator(), "/users/{id}", req.path, &req));
    try std.testing.expectEqualStrings("42", req.param("id").?);
}
