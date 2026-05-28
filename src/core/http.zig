const std = @import("std");

pub const Header = std.http.Header;

pub const HttpMethod = enum {
    get,
    post,
    put,
    delete,
    patch,
    head,
    options,
    unknown,

    pub fn fromBytes(method: []const u8) HttpMethod {
        if (std.mem.eql(u8, method, "GET")) return .get;
        if (std.mem.eql(u8, method, "POST")) return .post;
        if (std.mem.eql(u8, method, "PUT")) return .put;
        if (std.mem.eql(u8, method, "DELETE")) return .delete;
        if (std.mem.eql(u8, method, "PATCH")) return .patch;
        if (std.mem.eql(u8, method, "HEAD")) return .head;
        if (std.mem.eql(u8, method, "OPTIONS")) return .options;
        return .unknown;
    }

    pub fn fromStd(method: std.http.Method) HttpMethod {
        return switch (method) {
            .GET => .get,
            .POST => .post,
            .PUT => .put,
            .DELETE => .delete,
            .PATCH => .patch,
            .HEAD => .head,
            .OPTIONS => .options,
            else => .unknown,
        };
    }
};

pub const HttpStatus = enum(u10) {
    ok = 200,
    created = 201,
    no_content = 204,
    bad_request = 400,
    not_found = 404,
    method_not_allowed = 405,
    request_header_fields_too_large = 431,
    payload_too_large = 413,
    internal_server_error = 500,

    pub fn toStd(self: HttpStatus) std.http.Status {
        return @enumFromInt(@intFromEnum(self));
    }
};

pub const Params = std.StringHashMapUnmanaged([]const u8);

const max_inline_params = 8;

pub const Param = struct {
    name: []const u8,
    value: []const u8,
};

pub const HttpRequest = struct {
    allocator: std.mem.Allocator,
    method: HttpMethod,
    path: []const u8,
    target: []const u8,
    content_type: ?[]const u8 = null,
    content_length: ?u64 = null,
    keep_alive: bool = true,
    inline_params: [max_inline_params]Param = undefined,
    inline_param_count: u8 = 0,
    overflow_params: Params = .{},

    pub fn initParsed(
        allocator: std.mem.Allocator,
        method: []const u8,
        target: []const u8,
        content_type: ?[]const u8,
        content_length: ?u64,
        keep_alive: bool,
    ) HttpRequest {
        return .{
            .allocator = allocator,
            .method = .fromBytes(method),
            .path = stripQuery(target),
            .target = target,
            .content_type = content_type,
            .content_length = content_length,
            .keep_alive = keep_alive,
        };
    }

    pub fn init(allocator: std.mem.Allocator, head: std.http.Server.Request.Head) HttpRequest {
        const path = stripQuery(head.target);
        return .{
            .allocator = allocator,
            .method = .fromStd(head.method),
            .path = path,
            .target = head.target,
            .content_type = head.content_type,
            .content_length = head.content_length,
            .keep_alive = head.keep_alive,
        };
    }

    pub fn deinit(self: *HttpRequest) void {
        self.overflow_params.deinit(self.allocator);
    }

    pub fn setParam(self: *HttpRequest, name: []const u8, value: []const u8) !void {
        for (self.inline_params[0..self.inline_param_count]) |*param_entry| {
            if (std.mem.eql(u8, param_entry.name, name)) {
                param_entry.value = value;
                return;
            }
        }

        if (self.inline_param_count < max_inline_params) {
            self.inline_params[self.inline_param_count] = .{ .name = name, .value = value };
            self.inline_param_count += 1;
            return;
        }

        try self.overflow_params.put(self.allocator, name, value);
    }

    pub fn param(self: *const HttpRequest, name: []const u8) ?[]const u8 {
        for (self.inline_params[0..self.inline_param_count]) |param_entry| {
            if (std.mem.eql(u8, param_entry.name, name)) return param_entry.value;
        }
        return self.overflow_params.get(name);
    }

    pub fn paramCheckpoint(self: *const HttpRequest) u8 {
        return self.inline_param_count;
    }

    pub fn rollbackParams(self: *HttpRequest, checkpoint: u8) void {
        self.inline_param_count = checkpoint;
    }
};

pub const HttpResponse = struct {
    status: HttpStatus = .ok,
    body: []const u8 = "",
    content_type: []const u8 = "text/plain; charset=utf-8",
    extra_headers: []const Header = &.{},
    keep_alive: bool = true,

    pub fn ok(body: []const u8) HttpResponse {
        return .{ .body = body };
    }

    pub fn text(body: []const u8) HttpResponse {
        return .{ .body = body, .content_type = "text/plain; charset=utf-8" };
    }

    pub fn json(body: []const u8) HttpResponse {
        return .{ .body = body, .content_type = "application/json" };
    }

    pub fn notFound() HttpResponse {
        return .{ .status = .not_found, .body = "Not Found" };
    }

    pub fn methodNotAllowed(allow: []const u8) HttpResponse {
        return .{
            .status = .method_not_allowed,
            .body = "Method Not Allowed",
            .extra_headers = &.{.{ .name = "allow", .value = allow }},
        };
    }

    pub fn serverError() HttpResponse {
        return .{ .status = .internal_server_error, .body = "Internal Server Error" };
    }

    pub fn respond(self: HttpResponse, raw: *std.http.Server.Request) !void {
        var headers_buf: [8]Header = undefined;
        var count: usize = 0;
        headers_buf[count] = .{ .name = "content-type", .value = self.content_type };
        count += 1;
        for (self.extra_headers) |header| {
            if (count == headers_buf.len) break;
            headers_buf[count] = header;
            count += 1;
        }
        try raw.respond(self.body, .{
            .status = self.status.toStd(),
            .keep_alive = self.keep_alive,
            .extra_headers = headers_buf[0..count],
        });
    }
};

fn stripQuery(target: []const u8) []const u8 {
    return target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
}

test "request path strips query" {
    try std.testing.expectEqualStrings("/users", stripQuery("/users?page=1"));
}
