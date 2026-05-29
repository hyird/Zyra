//! 跨源资源共享（CORS）中间件。
//!
//! 使用 Zyra 携带上下文的洋葱中间件（无堆闭包）镜像 Hical 的
//! `makeCorsMiddleware` 行为：
//!
//! - 无 `Origin` 头                         -> 透传，不添加 CORS 头
//! - `Origin` 不在允许列表中                 -> 透传，不添加 CORS 头
//! - OPTIONS 预检（带 `Access-Control-Request-Method` 头）
//!                                           -> 响应 204 和完整预检头；不调用 `next`
//! - 其他跨源请求                            -> 调用 `next`，再追加简单 CORS 响应头
//! - `allow_credentials = true`              -> 回显具体 origin 而非 `*`
//!                                              （带凭据的通配符会在 `init` 时被拒绝）
//! - 非通配符模式                            -> 追加 `Vary: Origin`

const std = @import("std");
const http = @import("http.zig");
const middleware = @import("middleware.zig");

pub const CorsOptions = struct {
    /// 允许的源。`&.{"*"}` 允许任意源；否则逐字匹配源。
    allowed_origins: []const []const u8 = &.{"*"},
    /// 允许的 HTTP 方法，会在预检响应中声明。
    allowed_methods: []const []const u8 = &.{ "GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS" },
    /// 允许的请求头，会在预检响应中声明。
    allowed_headers: []const []const u8 = &.{ "Content-Type", "Authorization" },
    /// 在实际响应中暴露给客户端的响应头。
    expose_headers: []const []const u8 = &.{},
    /// 浏览器是否可以发送凭据（cookie、认证头）。
    allow_credentials: bool = false,
    /// 预检缓存生命周期（秒）。
    max_age_seconds: u32 = 86400,
};

pub const CorsError = error{
    /// `allow_credentials = true` 与 `*` origin 组合是不安全的，因此会被拒绝。
    CredentialsWithWildcardOrigin,
};

/// CORS 中间件。存储预先拼接好的头字符串，使请求处理避免每次调用都重新分配。
/// 用 `init` 构造，再用 `attach(server)` 或
/// `server.useOnionCtx(&cors, Cors.handle)` 注册。
pub const Cors = struct {
    options: CorsOptions,
    methods_csv: []u8,
    headers_csv: []u8,
    expose_csv: []u8,
    max_age_buf: [10]u8,
    max_age_len: usize,
    is_wildcard: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, options: CorsOptions) (CorsError || std.mem.Allocator.Error)!Cors {
        var is_wildcard = false;
        for (options.allowed_origins) |origin| {
            if (std.mem.eql(u8, origin, "*")) {
                is_wildcard = true;
                break;
            }
        }
        if (options.allow_credentials and is_wildcard) {
            return CorsError.CredentialsWithWildcardOrigin;
        }

        const methods_csv = try joinCsv(allocator, options.allowed_methods);
        errdefer allocator.free(methods_csv);
        const headers_csv = try joinCsv(allocator, options.allowed_headers);
        errdefer allocator.free(headers_csv);
        const expose_csv = try joinCsv(allocator, options.expose_headers);
        errdefer allocator.free(expose_csv);

        var self = Cors{
            .options = options,
            .methods_csv = methods_csv,
            .headers_csv = headers_csv,
            .expose_csv = expose_csv,
            .max_age_buf = undefined,
            .max_age_len = 0,
            .is_wildcard = is_wildcard,
            .allocator = allocator,
        };
        const formatted = std.fmt.bufPrint(&self.max_age_buf, "{d}", .{options.max_age_seconds}) catch unreachable;
        self.max_age_len = formatted.len;
        return self;
    }

    pub fn deinit(self: *Cors) void {
        self.allocator.free(self.methods_csv);
        self.allocator.free(self.headers_csv);
        self.allocator.free(self.expose_csv);
    }

    /// 在 `server` 上注册该 CORS 中间件。`self` 的生命周期必须长于 `server`。
    pub fn attach(self: *Cors, server: anytype) !void {
        try server.useOnionCtx(self, handle);
    }

    fn originAllowed(self: *const Cors, origin: []const u8) bool {
        for (self.options.allowed_origins) |allowed| {
            if (std.mem.eql(u8, allowed, "*")) return true;
            if (std.mem.eql(u8, allowed, origin)) return true;
        }
        return false;
    }

    fn applyCommonHeaders(self: *const Cors, response: *http.HttpResponse, allow_origin: []const u8) !void {
        try response.setHeader("Access-Control-Allow-Origin", allow_origin);
        if (self.options.allow_credentials) {
            try response.setHeader("Access-Control-Allow-Credentials", "true");
        }
        if (!self.is_wildcard) {
            try response.setHeader("Vary", "Origin");
        }
    }

    /// 上下文洋葱入口点。把 `ctx` 转回 `*Cors`。
    pub fn handle(ctx: *anyopaque, req: *http.HttpRequest, next: *middleware.Next) anyerror!http.HttpResponse {
        const self: *Cors = @ptrCast(@alignCast(ctx));

        const origin = req.header("Origin") orelse req.header("origin");
        if (origin == null or origin.?.len == 0) {
            return next.run(req);
        }
        const origin_value = origin.?;

        if (!self.originAllowed(origin_value)) {
            return next.run(req);
        }

        // 带凭据时，规范禁止 `*`；回显具体 origin。
        const allow_origin: []const u8 = if (self.options.allow_credentials or !self.is_wildcard)
            origin_value
        else
            "*";

        // 预检 = OPTIONS 加 Access-Control-Request-Method 头。裸 OPTIONS 请求
        // 正常路由。
        const req_method = req.header("Access-Control-Request-Method");
        const is_preflight = req.method == .options and req_method != null and req_method.?.len > 0;

        if (is_preflight) {
            var response = http.HttpResponse{ .status = .no_content };
            try self.applyCommonHeaders(&response, allow_origin);
            try response.setHeader("Access-Control-Allow-Methods", self.methods_csv);
            try response.setHeader("Access-Control-Allow-Headers", self.headers_csv);
            try response.setHeader("Access-Control-Max-Age", self.max_age_buf[0..self.max_age_len]);
            return response;
        }

        var response = try next.run(req);
        try self.applyCommonHeaders(&response, allow_origin);
        if (self.expose_csv.len > 0) {
            try response.setHeader("Access-Control-Expose-Headers", self.expose_csv);
        }
        return response;
    }
};

fn joinCsv(allocator: std.mem.Allocator, items: []const []const u8) ![]u8 {
    if (items.len == 0) return allocator.alloc(u8, 0);
    var total: usize = 0;
    for (items, 0..) |item, i| {
        if (i > 0) total += 2; // ", "
        total += item.len;
    }
    const buf = try allocator.alloc(u8, total);
    var pos: usize = 0;
    for (items, 0..) |item, i| {
        if (i > 0) {
            buf[pos] = ',';
            buf[pos + 1] = ' ';
            pos += 2;
        }
        @memcpy(buf[pos .. pos + item.len], item);
        pos += item.len;
    }
    return buf;
}

const router_mod = @import("router.zig");

fn buildPipeline(allocator: std.mem.Allocator, cors: *Cors) !middleware.MiddlewarePipeline {
    var pipeline = middleware.MiddlewarePipeline.init(allocator);
    try pipeline.useOnionCtx(cors, Cors.handle);
    return pipeline;
}

test "joinCsv joins with comma-space and handles empty" {
    const a = try joinCsv(std.testing.allocator, &.{ "GET", "POST", "PUT" });
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("GET, POST, PUT", a);

    const b = try joinCsv(std.testing.allocator, &.{});
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("", b);
}

test "init rejects credentials with wildcard origin" {
    try std.testing.expectError(
        CorsError.CredentialsWithWildcardOrigin,
        Cors.init(std.testing.allocator, .{ .allow_credentials = true, .allowed_origins = &.{"*"} }),
    );
}

test "request without Origin passes through untouched" {
    var router = router_mod.Router.init(std.testing.allocator);
    defer router.deinit();
    try router.get("/", helloHandler);

    var cors = try Cors.init(std.testing.allocator, .{});
    defer cors.deinit();
    var pipeline = try buildPipeline(std.testing.allocator, &cors);
    defer pipeline.deinit();

    var req: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/", .target = "/" };
    const response = try pipeline.execute(&router, &req);
    try std.testing.expectEqualStrings("hello", response.body);
    try std.testing.expect(response.header("Access-Control-Allow-Origin") == null);
}

test "disallowed origin passes through without CORS headers" {
    var router = router_mod.Router.init(std.testing.allocator);
    defer router.deinit();
    try router.get("/", helloHandler);

    var cors = try Cors.init(std.testing.allocator, .{ .allowed_origins = &.{"https://good.example"} });
    defer cors.deinit();
    var pipeline = try buildPipeline(std.testing.allocator, &cors);
    defer pipeline.deinit();

    var req: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/", .target = "/" };
    try req.addHeader("Origin", "https://evil.example");
    const response = try pipeline.execute(&router, &req);
    try std.testing.expectEqualStrings("hello", response.body);
    try std.testing.expect(response.header("Access-Control-Allow-Origin") == null);
}

test "allowed origin appends simple CORS headers" {
    var router = router_mod.Router.init(std.testing.allocator);
    defer router.deinit();
    try router.get("/", helloHandler);

    var cors = try Cors.init(std.testing.allocator, .{
        .allowed_origins = &.{"https://app.example"},
        .expose_headers = &.{"X-Total-Count"},
    });
    defer cors.deinit();
    var pipeline = try buildPipeline(std.testing.allocator, &cors);
    defer pipeline.deinit();

    var req: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/", .target = "/" };
    try req.addHeader("Origin", "https://app.example");
    const response = try pipeline.execute(&router, &req);
    try std.testing.expectEqualStrings("hello", response.body);
    try std.testing.expectEqualStrings("https://app.example", response.header("Access-Control-Allow-Origin").?);
    try std.testing.expectEqualStrings("Origin", response.header("Vary").?);
    try std.testing.expectEqualStrings("X-Total-Count", response.header("Access-Control-Expose-Headers").?);
}

test "wildcard origin echoes star without Vary" {
    var router = router_mod.Router.init(std.testing.allocator);
    defer router.deinit();
    try router.get("/", helloHandler);

    var cors = try Cors.init(std.testing.allocator, .{});
    defer cors.deinit();
    var pipeline = try buildPipeline(std.testing.allocator, &cors);
    defer pipeline.deinit();

    var req: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/", .target = "/" };
    try req.addHeader("Origin", "https://anything.example");
    const response = try pipeline.execute(&router, &req);
    try std.testing.expectEqualStrings("*", response.header("Access-Control-Allow-Origin").?);
    try std.testing.expect(response.header("Vary") == null);
}

test "preflight returns 204 with preflight headers" {
    var router = router_mod.Router.init(std.testing.allocator);
    defer router.deinit();
    try router.get("/", helloHandler);

    var cors = try Cors.init(std.testing.allocator, .{
        .allowed_origins = &.{"https://app.example"},
        .max_age_seconds = 600,
    });
    defer cors.deinit();
    var pipeline = try buildPipeline(std.testing.allocator, &cors);
    defer pipeline.deinit();

    var req: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .options, .path = "/", .target = "/" };
    try req.addHeader("Origin", "https://app.example");
    try req.addHeader("Access-Control-Request-Method", "POST");
    const response = try pipeline.execute(&router, &req);

    try std.testing.expectEqual(http.HttpStatus.no_content, response.status);
    try std.testing.expectEqualStrings("https://app.example", response.header("Access-Control-Allow-Origin").?);
    try std.testing.expect(response.header("Access-Control-Allow-Methods") != null);
    try std.testing.expect(response.header("Access-Control-Allow-Headers") != null);
    try std.testing.expectEqualStrings("600", response.header("Access-Control-Max-Age").?);
}

test "credentials echoes concrete origin and sets credentials header" {
    var router = router_mod.Router.init(std.testing.allocator);
    defer router.deinit();
    try router.get("/", helloHandler);

    var cors = try Cors.init(std.testing.allocator, .{
        .allowed_origins = &.{"https://app.example"},
        .allow_credentials = true,
    });
    defer cors.deinit();
    var pipeline = try buildPipeline(std.testing.allocator, &cors);
    defer pipeline.deinit();

    var req: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/", .target = "/" };
    try req.addHeader("Origin", "https://app.example");
    const response = try pipeline.execute(&router, &req);
    try std.testing.expectEqualStrings("https://app.example", response.header("Access-Control-Allow-Origin").?);
    try std.testing.expectEqualStrings("true", response.header("Access-Control-Allow-Credentials").?);
}

fn helloHandler(_: *http.HttpRequest) anyerror!http.HttpResponse {
    return http.HttpResponse.text("hello");
}
