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
    accepted = 202,
    no_content = 204,
    partial_content = 206,
    moved_permanently = 301,
    found = 302,
    not_modified = 304,
    temporary_redirect = 307,
    permanent_redirect = 308,
    bad_request = 400,
    unauthorized = 401,
    forbidden = 403,
    not_found = 404,
    method_not_allowed = 405,
    conflict = 409,
    request_header_fields_too_large = 431,
    payload_too_large = 413,
    requested_range_not_satisfiable = 416,
    too_many_requests = 429,
    internal_server_error = 500,
    not_implemented = 501,
    bad_gateway = 502,
    service_unavailable = 503,

    pub fn toStd(self: HttpStatus) std.http.Status {
        return @enumFromInt(@intFromEnum(self));
    }
};

pub const Params = std.StringHashMapUnmanaged([]const u8);
pub const QueryParams = std.StringArrayHashMapUnmanaged([]const u8);
pub const Attributes = std.StringArrayHashMapUnmanaged([]const u8);

const max_inline_params = 8;
const max_inline_headers = 64;
const max_inline_response_headers = 16;
const max_inline_cookies = 8;

pub const Param = struct {
    name: []const u8,
    value: []const u8,
};

pub const ResponseCookie = struct {
    name: []const u8,
    value: []const u8,
    options: CookieOptions = .{},
};

pub const SameSite = enum { lax, strict, none };

pub const CookieOptions = struct {
    max_age_seconds: ?i64 = null,
    expires: ?[]const u8 = null,
    path: ?[]const u8 = null,
    domain: ?[]const u8 = null,
    secure: bool = false,
    http_only: bool = false,
    same_site: ?SameSite = null,
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
    headers: [max_inline_headers]Header = undefined,
    header_count: u8 = 0,
    body_bytes: []const u8 = "",
    parsed_query_params: ?QueryParams = null,
    parsed_form_params: ?QueryParams = null,
    parsed_cookies: ?QueryParams = null,
    attributes: ?Attributes = null,

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

    pub fn initRaw(allocator: std.mem.Allocator, raw: *const std.http.Server.Request) !HttpRequest {
        const target = try allocator.dupe(u8, raw.head.target);
        var request = HttpRequest{
            .allocator = allocator,
            .method = .fromStd(raw.head.method),
            .path = stripQuery(target),
            .target = target,
            .content_type = if (raw.head.content_type) |ct| try allocator.dupe(u8, ct) else null,
            .content_length = raw.head.content_length,
            .keep_alive = raw.head.keep_alive,
        };
        var iter = raw.iterateHeaders();
        while (iter.next()) |entry| {
            const name = try allocator.dupe(u8, entry.name);
            const value = try allocator.dupe(u8, entry.value);
            try request.addHeader(name, value);
        }
        return request;
    }

    pub fn deinit(self: *HttpRequest) void {
        self.overflow_params.deinit(self.allocator);
        if (self.parsed_query_params) |*params| params.deinit(self.allocator);
        if (self.parsed_form_params) |*params| params.deinit(self.allocator);
        if (self.parsed_cookies) |*cookies_| cookies_.deinit(self.allocator);
        if (self.attributes) |*attrs| attrs.deinit(self.allocator);
    }

    pub fn addHeader(self: *HttpRequest, name: []const u8, value: []const u8) !void {
        if (self.header_count >= max_inline_headers) return error.TooManyHeaders;
        self.headers[self.header_count] = .{ .name = name, .value = value };
        self.header_count += 1;
    }

    pub fn header(self: *const HttpRequest, name: []const u8) ?[]const u8 {
        for (self.headers[0..self.header_count]) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.value;
        }
        return null;
    }

    pub fn hasHeader(self: *const HttpRequest, name: []const u8) bool {
        return self.header(name) != null;
    }

    pub fn query(self: *const HttpRequest) []const u8 {
        const question = std.mem.indexOfScalar(u8, self.target, '?') orelse return "";
        return self.target[question + 1 ..];
    }

    pub fn body(self: *const HttpRequest) []const u8 {
        return self.body_bytes;
    }

    pub fn contentType(self: *const HttpRequest) ?[]const u8 {
        return self.content_type orelse self.header("content-type");
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

    pub fn hasParam(self: *const HttpRequest, name: []const u8) bool {
        return self.param(name) != null;
    }

    pub fn queryParam(self: *HttpRequest, name: []const u8) !?[]const u8 {
        const params = try self.queryParams();
        return params.get(name);
    }

    pub fn hasQueryParam(self: *HttpRequest, name: []const u8) !bool {
        return (try self.queryParam(name)) != null;
    }

    pub fn queryParams(self: *HttpRequest) !*const QueryParams {
        if (self.parsed_query_params == null) {
            self.parsed_query_params = .{};
            try parseUrlEncoded(self.allocator, self.query(), &self.parsed_query_params.?);
        }
        return &self.parsed_query_params.?;
    }

    pub fn formParam(self: *HttpRequest, name: []const u8) !?[]const u8 {
        const params = try self.formParams();
        return params.get(name);
    }

    pub fn hasFormParam(self: *HttpRequest, name: []const u8) !bool {
        return (try self.formParam(name)) != null;
    }

    pub fn formParams(self: *HttpRequest) !*const QueryParams {
        if (self.parsed_form_params == null) {
            self.parsed_form_params = .{};
            if (self.contentType()) |ct| {
                if (std.mem.indexOf(u8, ct, "application/x-www-form-urlencoded") != null) {
                    try parseUrlEncoded(self.allocator, self.body_bytes, &self.parsed_form_params.?);
                }
            }
        }
        return &self.parsed_form_params.?;
    }

    pub fn cookie(self: *HttpRequest, name: []const u8) !?[]const u8 {
        const parsed = try self.cookies();
        return parsed.get(name);
    }

    pub fn hasCookie(self: *HttpRequest, name: []const u8) !bool {
        return (try self.cookie(name)) != null;
    }

    pub fn cookies(self: *HttpRequest) !*const QueryParams {
        if (self.parsed_cookies == null) {
            self.parsed_cookies = .{};
            if (self.header("cookie")) |cookie_header| {
                var parts = std.mem.splitScalar(u8, cookie_header, ';');
                while (parts.next()) |part_raw| {
                    const part = std.mem.trim(u8, part_raw, " \t");
                    const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
                    try self.parsed_cookies.?.put(self.allocator, part[0..eq], part[eq + 1 ..]);
                }
            }
        }
        return &self.parsed_cookies.?;
    }

    pub fn setAttribute(self: *HttpRequest, key: []const u8, value: []const u8) !void {
        if (self.attributes == null) self.attributes = .{};
        try self.attributes.?.put(self.allocator, key, value);
    }

    pub fn getAttribute(self: *const HttpRequest, key: []const u8) ?[]const u8 {
        if (self.attributes) |attrs| return attrs.get(key);
        return null;
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
    inline_headers: [max_inline_response_headers]Header = undefined,
    inline_header_count: u8 = 0,
    inline_cookies: [max_inline_cookies]ResponseCookie = undefined,
    inline_cookie_count: u8 = 0,
    content_range_buffer: [64]u8 = undefined,
    content_range_len: u8 = 0,

    pub fn ok(body: []const u8) HttpResponse {
        return .{ .body = body };
    }

    pub fn text(body: []const u8) HttpResponse {
        return .{ .body = body, .content_type = "text/plain; charset=utf-8" };
    }

    pub fn json(body: []const u8) HttpResponse {
        return .{ .body = body, .content_type = "application/json" };
    }

    pub fn badRequest(message: []const u8) HttpResponse {
        return .{ .status = .bad_request, .body = message };
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

    pub fn redirect(location: []const u8, status: HttpStatus) HttpResponse {
        var response = HttpResponse{ .status = status, .body = "" };
        response.setHeader("location", location) catch {};
        return response;
    }

    pub fn rangeNotSatisfiable(file_size: u64) HttpResponse {
        var response = HttpResponse{ .status = .requested_range_not_satisfiable, .body = "Range Not Satisfiable" };
        const value = std.fmt.bufPrint(&response.content_range_buffer, "bytes */{d}", .{file_size}) catch unreachable;
        response.content_range_len = @intCast(value.len);
        return response;
    }

    pub fn statusCode(self: *const HttpResponse) HttpStatus {
        return self.status;
    }

    pub fn setStatus(self: *HttpResponse, status: HttpStatus) void {
        self.status = status;
    }

    pub fn header(self: *const HttpResponse, name: []const u8) ?[]const u8 {
        if (std.ascii.eqlIgnoreCase(name, "content-type")) return self.content_type;
        if (std.ascii.eqlIgnoreCase(name, "content-range") and self.content_range_len > 0) {
            return self.content_range_buffer[0..self.content_range_len];
        }
        for (self.inline_headers[0..self.inline_header_count]) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.value;
        }
        for (self.extra_headers) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.value;
        }
        return null;
    }

    pub fn setHeader(self: *HttpResponse, name: []const u8, value: []const u8) !void {
        for (self.inline_headers[0..self.inline_header_count]) |*entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) {
                entry.value = value;
                return;
            }
        }
        if (std.ascii.eqlIgnoreCase(name, "content-type")) {
            self.content_type = value;
            return;
        }
        if (self.inline_header_count >= max_inline_response_headers) return error.TooManyHeaders;
        self.inline_headers[self.inline_header_count] = .{ .name = name, .value = value };
        self.inline_header_count += 1;
    }

    pub fn setBody(self: *HttpResponse, body_bytes: []const u8, content_type_: []const u8) void {
        self.body = body_bytes;
        self.content_type = content_type_;
    }

    pub fn bodyText(self: *const HttpResponse) []const u8 {
        return self.body;
    }

    pub fn setCookie(self: *HttpResponse, name: []const u8, value: []const u8, options: CookieOptions) !void {
        if (self.inline_cookie_count >= max_inline_cookies) return error.TooManyCookies;
        if (cookieWireLen(name, value, options) > 256) return error.CookieTooLong;
        self.inline_cookies[self.inline_cookie_count] = .{ .name = name, .value = value, .options = options };
        self.inline_cookie_count += 1;
    }

    pub fn respond(self: HttpResponse, raw: *std.http.Server.Request) !void {
        var headers_buf: [24]Header = undefined;
        var cookie_values: [max_inline_cookies][256]u8 = undefined;
        var count: usize = 0;
        headers_buf[count] = .{ .name = "content-type", .value = self.content_type };
        count += 1;
        for (self.inline_headers[0..self.inline_header_count]) |response_header| {
            if (count == headers_buf.len) break;
            headers_buf[count] = response_header;
            count += 1;
        }
        for (self.extra_headers) |extra_header| {
            if (count == headers_buf.len) break;
            headers_buf[count] = extra_header;
            count += 1;
        }
        if (self.content_range_len > 0 and count < headers_buf.len) {
            headers_buf[count] = .{ .name = "content-range", .value = self.content_range_buffer[0..self.content_range_len] };
            count += 1;
        }
        for (self.inline_cookies[0..self.inline_cookie_count], 0..) |cookie_entry, index| {
            if (count == headers_buf.len) break;
            const value = formatCookie(&cookie_values[index], cookie_entry) catch unreachable;
            headers_buf[count] = .{ .name = "set-cookie", .value = value };
            count += 1;
        }
        try raw.respond(self.body, .{
            .status = self.status.toStd(),
            .keep_alive = self.keep_alive,
            .extra_headers = headers_buf[0..count],
        });
    }
};

fn sameSiteText(value: SameSite) []const u8 {
    return switch (value) {
        .lax => "Lax",
        .strict => "Strict",
        .none => "None",
    };
}

fn cookieWireLen(name: []const u8, value: []const u8, options: CookieOptions) usize {
    var len = name.len + 1 + value.len;
    if (options.max_age_seconds) |max_age| len += "; Max-Age=".len + decimalLen(max_age);
    if (options.expires) |expires| len += "; Expires=".len + expires.len;
    if (options.path) |path| len += "; Path=".len + path.len;
    if (options.domain) |domain| len += "; Domain=".len + domain.len;
    if (options.secure) len += "; Secure".len;
    if (options.http_only) len += "; HttpOnly".len;
    if (options.same_site) |same_site| len += "; SameSite=".len + sameSiteText(same_site).len;
    return len;
}

fn decimalLen(value: i64) usize {
    var len: usize = if (value < 0) 1 else 0;
    var n: u64 = if (value < 0) @intCast(-value) else @intCast(value);
    while (true) {
        len += 1;
        n /= 10;
        if (n == 0) break;
    }
    return len;
}

fn formatCookie(buffer: []u8, cookie_entry: ResponseCookie) ![]const u8 {
    var stream = std.Io.Writer.fixed(buffer);
    const writer = &stream;
    try writer.print("{s}={s}", .{ cookie_entry.name, cookie_entry.value });
    if (cookie_entry.options.max_age_seconds) |max_age| try writer.print("; Max-Age={d}", .{max_age});
    if (cookie_entry.options.expires) |expires| try writer.print("; Expires={s}", .{expires});
    if (cookie_entry.options.path) |path| try writer.print("; Path={s}", .{path});
    if (cookie_entry.options.domain) |domain| try writer.print("; Domain={s}", .{domain});
    if (cookie_entry.options.secure) try writer.writeAll("; Secure");
    if (cookie_entry.options.http_only) try writer.writeAll("; HttpOnly");
    if (cookie_entry.options.same_site) |same_site| try writer.print("; SameSite={s}", .{sameSiteText(same_site)});
    return buffer[0..writer.end];
}

fn parseUrlEncoded(allocator: std.mem.Allocator, input: []const u8, out: *QueryParams) !void {
    var pairs = std.mem.splitScalar(u8, input, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const key = try percentDecode(allocator, pair[0..eq]);
        const value = if (eq < pair.len) try percentDecode(allocator, pair[eq + 1 ..]) else "";
        try out.put(allocator, key, value);
    }
}

fn percentDecode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var needs_decode = false;
    for (input) |c| {
        if (c == '%' or c == '+') {
            needs_decode = true;
            break;
        }
    }
    if (!needs_decode) return input;

    var decoded = try allocator.alloc(u8, input.len);
    var out: usize = 0;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '+') {
            decoded[out] = ' ';
        } else if (input[i] == '%' and i + 2 < input.len) {
            decoded[out] = std.fmt.parseInt(u8, input[i + 1 .. i + 3], 16) catch input[i];
            i += 2;
        } else {
            decoded[out] = input[i];
        }
        out += 1;
    }
    return decoded[0..out];
}


fn stripQuery(target: []const u8) []const u8 {
    return target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
}

test "request path strips query" {
    try std.testing.expectEqualStrings("/users", stripQuery("/users?page=1"));
}

test "request helpers parse headers query cookies and attributes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = HttpRequest.initParsed(arena.allocator(), "GET", "/users?page=1&name=zig+web", null, null, true);
    defer req.deinit();
    try req.addHeader("Cookie", "sid=abc; theme=dark");

    try std.testing.expectEqualStrings("/users", req.path);
    try std.testing.expectEqualStrings("page=1&name=zig+web", req.query());
    try std.testing.expectEqualStrings("1", (try req.queryParam("page")).?);
    try std.testing.expectEqualStrings("zig web", (try req.queryParam("name")).?);
    try std.testing.expectEqualStrings("abc", (try req.cookie("sid")).?);

    try req.setAttribute("trace_id", "t1");
    try std.testing.expectEqualStrings("t1", req.getAttribute("trace_id").?);
}

test "http method conversions" {
    try std.testing.expectEqual(HttpMethod.get, HttpMethod.fromBytes("GET"));
    try std.testing.expectEqual(HttpMethod.post, HttpMethod.fromBytes("POST"));
    try std.testing.expectEqual(HttpMethod.unknown, HttpMethod.fromBytes("BREW"));

    try std.testing.expectEqual(HttpMethod.delete, HttpMethod.fromStd(.DELETE));
}

test "http status converts to std status" {
    try std.testing.expectEqual(std.http.Status.ok, HttpStatus.ok.toStd());
    try std.testing.expectEqual(std.http.Status.not_found, HttpStatus.not_found.toStd());
    try std.testing.expectEqual(std.http.Status.method_not_allowed, HttpStatus.method_not_allowed.toStd());
    try std.testing.expectEqual(std.http.Status.internal_server_error, HttpStatus.internal_server_error.toStd());
}

test "request init helpers and basic accessors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parsed = HttpRequest.initParsed(arena.allocator(), "GET", "/items?a=1", null, null, false);
    defer parsed.deinit();
    try std.testing.expectEqual(HttpMethod.get, parsed.method);
    try std.testing.expectEqualStrings("/items", parsed.path);
    try std.testing.expectEqualStrings("a=1", parsed.query());
    try std.testing.expectEqualStrings("", parsed.body());
    try std.testing.expectEqual(false, parsed.keep_alive);

    const head = std.http.Server.Request.Head{
        .method = .POST,
        .target = "/submit?x=1",
        .version = .@"HTTP/1.1",
        .expect = null,
        .content_type = "text/plain",
        .content_length = 4,
        .transfer_encoding = .none,
        .transfer_compression = .identity,
        .keep_alive = true,
    };
    var request_from_head = HttpRequest.init(arena.allocator(), head);
    defer request_from_head.deinit();
    try std.testing.expectEqual(HttpMethod.post, request_from_head.method);
    try std.testing.expectEqualStrings("/submit", request_from_head.path);
    try std.testing.expectEqualStrings("text/plain", request_from_head.contentType().?);
}

test "request headers params and rollback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = HttpRequest.initParsed(arena.allocator(), "GET", "/", null, null, true);
    defer req.deinit();

    try req.addHeader("X-Test", "1");
    try std.testing.expectEqualStrings("1", req.header("x-test").?);
    try std.testing.expect(req.hasHeader("X-Test"));

    try req.setParam("one", "1");
    const checkpoint = req.paramCheckpoint();
    try req.setParam("two", "2");
    try std.testing.expectEqualStrings("2", req.param("two").?);
    req.rollbackParams(checkpoint);
    try std.testing.expect(req.param("two") == null);
    try std.testing.expect(req.hasParam("one"));
}

test "request helpers parse form body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = HttpRequest.initParsed(arena.allocator(), "POST", "/submit", "application/x-www-form-urlencoded", 17, true);
    defer req.deinit();
    req.body_bytes = "name=zig+web&x=1";

    try std.testing.expectEqualStrings("zig web", (try req.formParam("name")).?);
    try std.testing.expectEqualStrings("1", (try req.formParam("x")).?);
    try std.testing.expect(try req.hasFormParam("name"));
}

test "request query form and cookie parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = HttpRequest.initParsed(arena.allocator(), "POST", "/search?q=zig+lang&encoded=a%2Bb", "application/x-www-form-urlencoded", 0, true);
    defer req.deinit();
    req.body_bytes = "form=a+b&other=hello%21";
    try req.addHeader("Cookie", "sid=abc; theme=dark; spaced=hello+world");

    const qparams = try req.queryParams();
    try std.testing.expectEqualStrings("zig lang", qparams.get("q").?);
    try std.testing.expectEqualStrings("a+b", qparams.get("encoded").?);
    try std.testing.expect(try req.hasQueryParam("q"));

    const fparams = try req.formParams();
    try std.testing.expectEqualStrings("a b", fparams.get("form").?);
    try std.testing.expectEqualStrings("hello!", fparams.get("other").?);
    try std.testing.expect(try req.hasFormParam("other"));

    const cookies = try req.cookies();
    try std.testing.expectEqualStrings("abc", cookies.get("sid").?);
    try std.testing.expectEqualStrings("dark", (try req.cookie("theme")).?);
    try std.testing.expect(try req.hasCookie("sid"));
}

test "request content type prefers explicit value then header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = HttpRequest.initParsed(arena.allocator(), "POST", "/", "application/json", null, true);
    defer req.deinit();
    try req.addHeader("Content-Type", "text/plain");
    try std.testing.expectEqualStrings("application/json", req.contentType().?);

    var other = HttpRequest.initParsed(arena.allocator(), "POST", "/", null, null, true);
    defer other.deinit();
    try other.addHeader("Content-Type", "text/plain");
    try std.testing.expectEqualStrings("text/plain", other.contentType().?);
}

test "response helpers set status headers and body" {
    var res = HttpResponse.ok("hello");
    res.setStatus(.created);
    try res.setHeader("x-test", "1");
    res.setBody("{}", "application/json");

    try std.testing.expectEqual(HttpStatus.created, res.statusCode());
    try std.testing.expectEqualStrings("1", res.header("X-Test").?);
    try std.testing.expectEqualStrings("{}", res.bodyText());
    try std.testing.expectEqualStrings("application/json", res.header("content-type").?);
}

test "response helper factories" {
    const ok = HttpResponse.ok("hello");
    try std.testing.expectEqual(HttpStatus.ok, ok.status);
    try std.testing.expectEqualStrings("hello", ok.body);

    const text = HttpResponse.text("hello");
    try std.testing.expectEqualStrings("text/plain; charset=utf-8", text.content_type);

    const json = HttpResponse.json("{}");
    try std.testing.expectEqualStrings("application/json", json.content_type);

    const not_found = HttpResponse.notFound();
    try std.testing.expectEqual(HttpStatus.not_found, not_found.status);

    const method_not_allowed = HttpResponse.methodNotAllowed("GET, POST");
    try std.testing.expectEqualStrings("GET, POST", method_not_allowed.header("allow").?);

    const server_error = HttpResponse.serverError();
    try std.testing.expectEqual(HttpStatus.internal_server_error, server_error.status);

    const bad = HttpResponse.badRequest("bad");
    try std.testing.expectEqual(HttpStatus.bad_request, bad.status);

    const redirect_response = HttpResponse.redirect("/next", .found);
    try std.testing.expectEqual(HttpStatus.found, redirect_response.status);
    try std.testing.expectEqualStrings("/next", redirect_response.header("Location").?);

    const range = HttpResponse.rangeNotSatisfiable(123);
    try std.testing.expectEqual(HttpStatus.requested_range_not_satisfiable, range.status);
}

test "response body header and cookie helpers" {
    var res = HttpResponse.ok("body");
    try res.setHeader("X-Test", "1");
    try res.setHeader("content-type", "application/octet-stream");
    try res.setCookie("sid", "abc", .{ .path = "/", .http_only = true, .same_site = .lax });

    try std.testing.expectEqualStrings("1", res.header("x-test").?);
    try std.testing.expectEqualStrings("application/octet-stream", res.header("content-type").?);
    try std.testing.expectEqualStrings("body", res.bodyText());
    try std.testing.expectEqual(@as(u8, 1), res.inline_cookie_count);
    try std.testing.expectEqualStrings("sid", res.inline_cookies[0].name);
    try std.testing.expectEqualStrings("abc", res.inline_cookies[0].value);
}

test "response factories cover common Hical web helpers" {
    const bad = HttpResponse.badRequest("bad");
    try std.testing.expectEqual(HttpStatus.bad_request, bad.status);
    try std.testing.expectEqualStrings("bad", bad.body);

    const redirect_response = HttpResponse.redirect("/next", .found);
    try std.testing.expectEqual(HttpStatus.found, redirect_response.status);
    try std.testing.expectEqualStrings("/next", redirect_response.header("Location").?);

    const range = HttpResponse.rangeNotSatisfiable(123);
    try std.testing.expectEqual(HttpStatus.requested_range_not_satisfiable, range.status);
}
