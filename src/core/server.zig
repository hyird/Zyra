const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");
const Io = std.Io;

const http = @import("http.zig");
const Router = @import("router.zig").Router;
const MiddlewarePipeline = @import("middleware.zig").MiddlewarePipeline;
const MemoryPool = @import("memory_pool.zig").MemoryPool;
const websocket = @import("websocket.zig");
const openapi = @import("openapi.zig");
const typed_route = @import("typed_route.zig");

/// 记录一条类型化路由的 OpenAPI 元数据。`register` 是一个编译期生成的
/// 函数，把该路由反射出的请求/响应 schema 加入文档；`Request`/`Response`
/// 类型被捕获在它内部，因此无需存储任何运行时类型信息。
const TypedRouteRecord = struct {
    method: http.HttpMethod,
    path: []const u8,
    summary: []const u8,
    register: *const fn (*openapi.OpenApiDocument, http.HttpMethod, []const u8, []const u8) anyerror!void,
};

/// zio 的 `ExecutorCount` 类型，从 `Runtime.init` 的选项参数中取回，因为
/// 根 `zio` 模块并不直接重新导出它。
const RuntimeOptions = @typeInfo(@TypeOf(zio.Runtime.init)).@"fn".params[1].type.?;
const ExecutorCount = @FieldType(RuntimeOptions, "executors");

pub const ErrorHandler = *const fn (?*anyopaque, *http.HttpRequest, anyerror) anyerror!http.HttpResponse;

pub const ServerOptions = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 3000,
    /// zio 执行器（I/O 线程）数量。0 让 zio 根据 CPU 数量自动检测。
    /// Windows 被强制为单执行器，以避免跨 IOCP 的套接字 I/O。
    io_threads: usize = 0,
    max_request_header_size: usize = 64 * 1024,
    max_request_body_size: usize = 1024 * 1024,
    max_connections: usize = 10_000,
    write_buffer_size: usize = 4096,
    /// 空闲（keep-alive）超时，单位毫秒。在 keep-alive 连接上等待下一个
    /// 请求头时，套接字读取以此为期限；若到时仍无数据则关闭连接。
    /// 0 禁用超时（无限等待）。该超时仅作用于请求之间的等待，不影响
    /// 进行中的请求处理。
    idle_timeout_ms: u64 = 0,
};

pub const HttpServer = struct {
    allocator: std.mem.Allocator,
    options: ServerOptions,
    router_: Router,
    middleware_: MiddlewarePipeline,
    memory_pool: MemoryPool,
    active_connections: std.atomic.Value(usize),
    /// 由 `requestShutdown` 触发以开始优雅关闭：accept 循环停止接收新连接，
    /// 在 `start` 返回前排空进行中的处理函数。线程安全；可从其他线程设置。
    shutdown_event: std.Io.Event = .unset,
    /// 一旦 accept 循环停止接收新连接即被设置，使处理函数（和测试）能观察到
    /// 正在进行排空。
    accepting: std.atomic.Value(bool) = .init(false),
    /// 预生成的 OpenAPI JSON 文档，设置后在 `openapi_path` 提供。
    openapi_json: ?[]const u8 = null,
    openapi_path: []const u8 = "/openapi.json",
    /// 通过类型化 JSON 辅助函数（`getJson`/`postJson`/...）注册的路由的
    /// OpenAPI 元数据。由 `enableOpenApi` 用于输出反射出的请求/响应 schema。
    typed_routes: std.ArrayListUnmanaged(TypedRouteRecord) = .empty,
    /// 可选的启动钩子：在 `start` 内部、zio 运行时已就绪且开始 accept
    /// *之前*被调用一次，并拿到运行时的 `std.Io`。用于初始化需要 io 的
    /// 资源（如 `FileSink`/`AsyncFileSink` 日志 sink）。`ctx` 原样回传。
    on_ready_ctx: ?*anyopaque = null,
    on_ready_fn: ?*const fn (?*anyopaque, Io) anyerror!void = null,
    /// 可选的全局错误处理器：当业务 handler / 中间件返回 error 时调用，用于
    /// 将服务层错误统一映射为 HTTP 响应。未设置时保持默认 500。
    error_handler_ctx: ?*anyopaque = null,
    error_handler_fn: ?ErrorHandler = null,

    pub fn init(allocator: std.mem.Allocator, options: ServerOptions) HttpServer {
        return .{
            .allocator = allocator,
            .options = options,
            .router_ = Router.init(allocator),
            .middleware_ = MiddlewarePipeline.init(allocator),
            .memory_pool = MemoryPool.init(allocator),
            .active_connections = .init(0),
        };
    }

    pub fn deinit(self: *HttpServer) void {
        if (self.openapi_json) |json| self.allocator.free(json);
        self.typed_routes.deinit(self.allocator);
        self.middleware_.deinit();
        self.router_.deinit();
    }

    pub fn router(self: *HttpServer) *Router {
        return &self.router_;
    }

    pub fn use(self: *HttpServer, middleware: @import("middleware.zig").Middleware) !void {
        try self.middleware_.use(middleware);
    }

    pub fn useOnion(self: *HttpServer, middleware: @import("middleware.zig").MiddlewareHandler) !void {
        try self.middleware_.useOnion(middleware);
    }

    /// 注册一个携带上下文的洋葱中间件（例如 CORS、会话）。`context` 必须
    /// 比服务器存活更久。
    pub fn useOnionCtx(
        self: *HttpServer,
        context: *anyopaque,
        handler: @import("middleware.zig").ContextHandler,
    ) !void {
        try self.middleware_.useOnionCtx(context, handler);
    }

    pub fn useBeforeAfter(
        self: *HttpServer,
        before: @import("middleware.zig").BeforeHandler,
        after: ?@import("middleware.zig").AfterHandler,
    ) !void {
        try self.middleware_.useBeforeAfter(before, after);
    }

    /// 为精确路径注册一个 WebSocket 处理函数。服务器会升级匹配的请求，并
    /// 以一个 `WebSocketSession` 运行该处理函数。
    pub fn ws(self: *HttpServer, path: []const u8, handler: @import("router.zig").WsHandler) !void {
        try self.router_.ws(path, handler);
    }

    /// 类型化 JSON 路由辅助函数的选项。
    pub const JsonRouteOptions = struct {
        summary: []const u8 = "",
    };

    /// 注册一条类型化 JSON 路由。`handler` 形如
    /// `fn(*HttpRequest, Body) E!Response` 或 `fn(*HttpRequest) E!Response`，
    /// 其中 `Body`/`Response` 是 Zig 类型。框架会把 JSON 请求体解析为 `Body`
    /// （JSON 格式错误时返回 400），调用处理函数，并把返回值序列化为 JSON
    /// 响应（`void` 产生空的 200）。当调用 `enableOpenApi` 时，请求/响应类型
    /// 会被反射进 OpenAPI schema。
    pub fn routeJson(
        self: *HttpServer,
        method: http.HttpMethod,
        path: []const u8,
        comptime handler: anytype,
        options: JsonRouteOptions,
    ) !void {
        try self.router_.route(method, path, typed_route.wrap(handler));
        const ti = comptime typed_route.infoOf(handler);
        const register = struct {
            fn reg(
                doc: *openapi.OpenApiDocument,
                m: http.HttpMethod,
                p: []const u8,
                summary: []const u8,
            ) anyerror!void {
                try doc.addJsonOperation(ti.Body, ti.Response, m, p, .{ .summary = summary });
            }
        }.reg;
        try self.typed_routes.append(self.allocator, .{
            .method = method,
            .path = path,
            .summary = options.summary,
            .register = register,
        });
    }

    pub fn getJson(self: *HttpServer, path: []const u8, comptime handler: anytype, options: JsonRouteOptions) !void {
        try self.routeJson(.get, path, handler, options);
    }

    pub fn postJson(self: *HttpServer, path: []const u8, comptime handler: anytype, options: JsonRouteOptions) !void {
        try self.routeJson(.post, path, handler, options);
    }

    pub fn putJson(self: *HttpServer, path: []const u8, comptime handler: anytype, options: JsonRouteOptions) !void {
        try self.routeJson(.put, path, handler, options);
    }

    pub fn patchJson(self: *HttpServer, path: []const u8, comptime handler: anytype, options: JsonRouteOptions) !void {
        try self.routeJson(.patch, path, handler, options);
    }

    pub fn deleteJson(self: *HttpServer, path: []const u8, comptime handler: anytype, options: JsonRouteOptions) !void {
        try self.routeJson(.delete, path, handler, options);
    }

    /// 从当前所有已注册路由生成一份 OpenAPI 3.0.3 文档，并在 `/openapi.json`
    /// 提供。请在注册完路由后调用。会替换任何先前生成的文档。
    pub fn enableOpenApi(self: *HttpServer, config: openapi.Config) !void {
        var doc = openapi.OpenApiDocument.init(self.allocator, config);
        defer doc.deinit();
        // 先处理类型化 JSON 路由，以记录它们反射出的 schema；随后
        // `collectFromRouter` 补齐其余普通路由，且不覆盖已记录的。
        for (self.typed_routes.items) |record| {
            try record.register(&doc, record.method, record.path, record.summary);
        }
        try doc.collectFromRouter(&self.router_);
        const json = try doc.generate();
        if (self.openapi_json) |old| self.allocator.free(old);
        self.openapi_json = json;
    }

    pub fn setMaxBodySize(self: *HttpServer, bytes: usize) void {
        self.options.max_request_body_size = bytes;
    }

    pub fn setMaxHeaderSize(self: *HttpServer, bytes: usize) void {
        self.options.max_request_header_size = bytes;
    }

    pub fn setMaxConnections(self: *HttpServer, max_connections: usize) void {
        self.options.max_connections = max_connections;
    }

    pub fn recommendedMaxConnections(available_memory_mb: usize) usize {
        const by_memory = (available_memory_mb * 1024 * 70) / (100 * 25);
        return @min(by_memory, 65_535);
    }

    pub fn port(self: *const HttpServer) u16 {
        return self.options.port;
    }

    pub fn start(self: *HttpServer) !void {
        var runtime = try zio.Runtime.init(self.allocator, .{ .executors = self.executorOption() });
        defer runtime.deinit();

        const io = runtime.io();
        const addr = try Io.net.IpAddress.parseIp4(self.options.host, self.options.port);
        var listener = try addr.listen(io, .{ .reuse_address = true });
        defer listener.deinit(io);

        std.log.info("Zyra listening on {f}", .{listener.socket.address});

        // 进行中的连接处理函数存活在这个 group 中。关闭时我们对该 group
        // 执行 `await`（而非 `cancel`），让活跃请求完成排空。
        var group: Io.Group = .init;

        // 在开始 accept 之前运行启动钩子，让用户初始化依赖 io 的资源。
        if (self.on_ready_fn) |hook| try hook(self.on_ready_ctx, io);

        self.accepting.store(true, .release);

        // 并发运行 accept 循环，使调用方 fiber 可以等待关闭信号。当该信号
        // 到来时取消 accept 循环，从而在其下一个取消点中断阻塞的 `accept`。
        var accept_future = io.async(HttpServer.acceptLoop, .{ self, io, &listener, &group });

        // 阻塞直到请求优雅关闭（若从不请求则一直阻塞）。
        self.shutdown_event.waitUncancelable(io);

        // 停止接收新连接，然后排空已在运行的处理函数。
        self.accepting.store(false, .release);
        _ = accept_future.cancel(io);
        group.await(io) catch {};
    }

    /// 注册一个启动钩子：在运行时就绪、开始 accept 之前，于 zio 运行时
    /// 的 fiber 上下文中以 `(ctx, io)` 调用一次。返回错误会使 `start`
    /// 失败。典型用途是 open 并 start 依赖 io 的日志 sink。
    pub fn onReady(
        self: *HttpServer,
        ctx: ?*anyopaque,
        handler: *const fn (?*anyopaque, Io) anyerror!void,
    ) void {
        self.on_ready_ctx = ctx;
        self.on_ready_fn = handler;
    }

    /// 设置全局错误处理器。业务处理函数或中间件可以直接返回 error；服务器会
    /// 调用该 handler，把 `(req, err)` 映射成 HTTP 响应。若错误处理器自身失败，
    /// 则回退到默认的 500 响应。
    pub fn setErrorHandler(self: *HttpServer, ctx: ?*anyopaque, handler: ErrorHandler) void {
        self.error_handler_ctx = ctx;
        self.error_handler_fn = handler;
    }

    /// 请求优雅关闭：停止接收新连接，并在 `start` 返回前让进行中的请求
    /// 完成。线程安全；可从其他 fiber/线程调用（例如信号处理桥接）。
    pub fn requestShutdown(self: *HttpServer, io: Io) void {
        self.shutdown_event.set(io);
    }

    /// 服务器仍在接收新连接时为 true。一旦优雅关闭开始即变为 false。
    pub fn isAccepting(self: *const HttpServer) bool {
        return self.accepting.load(.acquire);
    }

    /// accept 循环，作为可取消任务运行。取消（由 `requestShutdown` 触发）
    /// 表现为 `accept` 返回 `error.Canceled`，从而结束循环且不再接收连接。
    fn acceptLoop(self: *HttpServer, io: Io, listener: *Io.net.Server, group: *Io.Group) void {
        while (true) {
            const stream = listener.accept(io) catch return;
            if (!self.tryAcquireConnection()) {
                stream.close(io);
                continue;
            }
            group.concurrent(io, handleClient, .{ self, io, stream }) catch {
                self.releaseConnection();
                stream.close(io);
            };
        }
    }

    fn tryAcquireConnection(self: *HttpServer) bool {
        if (self.options.max_connections == 0) {
            _ = self.active_connections.fetchAdd(1, .acq_rel);
            return true;
        }

        var current = self.active_connections.load(.acquire);
        while (current < self.options.max_connections) {
            if (self.active_connections.cmpxchgWeak(current, current + 1, .acq_rel, .acquire)) |actual| {
                current = actual;
            } else {
                return true;
            }
        }
        return false;
    }

    fn releaseConnection(self: *HttpServer) void {
        _ = self.active_connections.fetchSub(1, .acq_rel);
    }

    /// 解析 zio 执行器配置。Windows 被强制为单执行器；其他平台上
    /// `io_threads == 0` 交给 zio 的 CPU 自动检测（`.auto`），任何其他值
    /// 原样使用（钳制到运行时支持的范围内）。
    fn executorOption(self: *const HttpServer) ExecutorCount {
        if (builtin.os.tag == .windows) return .exact(1);
        if (self.options.io_threads == 0) return .auto;
        const clamped: u8 = @intCast(@min(@max(self.options.io_threads, 1), max_executors));
        return .exact(clamped);
    }

    const max_executors = 64;
    const inline_read_buffer_size = 64 * 1024;
    const inline_write_buffer_size = 4096;

    /// 把配置的 `idle_timeout_ms` 映射为 zio 读超时：0 表示无超时（无限
    /// 等待），其他值为毫秒时长。
    fn idleTimeout(self: *const HttpServer) zio.Timeout {
        if (self.options.idle_timeout_ms == 0) return .none;
        return .fromMilliseconds(self.options.idle_timeout_ms);
    }

    fn handleClient(self: *HttpServer, io: Io, stream: Io.net.Stream) Io.Cancelable!void {
        defer self.releaseConnection();
        defer stream.close(io);

        // 默认配置下把连接级读/写缓冲放在当前处理函数的栈帧里，避免每个
        // 连接都向全局 allocator 申请两块短生命周期内存。用户把缓冲大小调
        // 到内联容量以上时，再回退到堆分配以保留可配置性。
        var inline_read_buffer: [inline_read_buffer_size]u8 = undefined;
        var heap_read_buffer: ?[]u8 = null;
        defer if (heap_read_buffer) |buffer| self.allocator.free(buffer);
        const read_buffer = if (self.options.max_request_header_size <= inline_read_buffer.len)
            inline_read_buffer[0..self.options.max_request_header_size]
        else blk: {
            const buffer = self.allocator.alloc(u8, self.options.max_request_header_size) catch return;
            heap_read_buffer = buffer;
            break :blk buffer;
        };
        var reader = zio.net.Stream.Reader.fromStd(stream, io, read_buffer);

        var inline_write_buffer: [inline_write_buffer_size]u8 = undefined;
        var heap_write_buffer: ?[]u8 = null;
        defer if (heap_write_buffer) |buffer| self.allocator.free(buffer);
        const write_buffer = if (self.options.write_buffer_size <= inline_write_buffer.len)
            inline_write_buffer[0..self.options.write_buffer_size]
        else blk: {
            const buffer = self.allocator.alloc(u8, self.options.write_buffer_size) catch return;
            heap_write_buffer = buffer;
            break :blk buffer;
        };
        var writer = zio.net.Stream.Writer.fromStd(stream, io, write_buffer);

        var raw_server = std.http.Server.init(&reader.interface, &writer.interface);

        // 空闲超时（若配置）仅限制 keep-alive 请求之间对下一个请求头的
        // 等待。它在 `receiveHead` 前装载，并在请求头到达后清除，因此不
        // 影响进行中的请求体读取。zio 把它实现为事件循环内 recv + 定时器
        // 完成的竞争（无额外协程），这是在 epoll/io_uring 就绪模型下唯一
        // 真正会触发的超时机制。
        const idle_timeout = self.idleTimeout();
        const has_idle_timeout = idle_timeout != .none;
        const has_middleware = self.middleware_.size() != 0;
        const has_websocket_routes = self.router_.hasWebSocketRoutes();

        while (true) {
            if (has_idle_timeout) reader.setTimeout(idle_timeout);
            var raw_request = raw_server.receiveHead() catch |err| switch (err) {
                error.ReadFailed => return cancelOrClose(reader.err),
                error.HttpConnectionClosing => return,
                else => return,
            };
            if (has_idle_timeout) reader.setTimeout(.none);
            const keep_alive = raw_request.head.keep_alive;

            // WebSocket 升级：若客户端请求升级，且本路径注册了处理函数，
            // 则接管该连接。
            if (has_websocket_routes and raw_request.upgradeRequested() == .websocket) {
                const ws_path = http.stripQuery(raw_request.head.target);
                if (self.router_.wsHandler(ws_path)) |handler| {
                    try self.serveWebSocket(&raw_request, handler);
                    return;
                }
            }

            var arena = self.memory_pool.requestArena();
            defer arena.deinit();

            var request = http.HttpRequest.initRaw(arena.allocator(), &raw_request) catch return;
            defer request.deinit();
            request.io = io;

            // 提供缓存的 OpenAPI 文档（若已启用）。
            if (self.openapi_json) |json| {
                if (request.method == .get and std.mem.eql(u8, request.path, self.openapi_path)) {
                    var response = http.HttpResponse{
                        .status = .ok,
                        .body = json,
                        .content_type = "application/json; charset=utf-8",
                        .keep_alive = keep_alive,
                    };
                    response.respond(&raw_request) catch |err| switch (err) {
                        error.WriteFailed => return cancelOrClose(writer.err),
                        else => return,
                    };
                    if (!keep_alive) break;
                    continue;
                }
            }

            if (request.content_length) |content_length| {
                if (content_length > self.options.max_request_body_size) {
                    var response = http.HttpResponse{ .status = .payload_too_large, .body = "Payload Too Large", .keep_alive = false };
                    response.respond(&raw_request) catch |err| switch (err) {
                        error.WriteFailed => return cancelOrClose(writer.err),
                        else => return,
                    };
                    return;
                }

                if (content_length > 0) {
                    raw_request.writeExpectContinue() catch |err| switch (err) {
                        error.WriteFailed => return cancelOrClose(writer.err),
                        else => return,
                    };

                    var body_buffer: [4096]u8 = undefined;
                    const body_reader = raw_request.readerExpectNone(&body_buffer);
                    request.body_bytes = body_reader.readAlloc(arena.allocator(), @intCast(content_length)) catch |err| switch (err) {
                        error.ReadFailed => return cancelOrClose(reader.err),
                        else => return,
                    };
                }
            }

            var response = if (has_middleware)
                self.middleware_.execute(&self.router_, &request) catch |err| self.handleError(&request, err)
            else
                self.router_.dispatch(&request) catch |err| self.handleError(&request, err);
            response.keep_alive = keep_alive;
            response.respondWithIo(&raw_request, io) catch |err| switch (err) {
                error.WriteFailed => return cancelOrClose(writer.err),
                else => return,
            };

            if (!keep_alive) break;
        }
    }

    fn handleError(self: *HttpServer, req: *http.HttpRequest, err: anyerror) http.HttpResponse {
        if (self.error_handler_fn) |handler| {
            return handler(self.error_handler_ctx, req, err) catch http.HttpResponse.serverError();
        }
        return http.HttpResponse.serverError();
    }

    /// 完成 WebSocket 握手并运行已注册的处理函数。
    fn serveWebSocket(
        self: *HttpServer,
        raw_request: *std.http.Server.Request,
        handler: @import("router.zig").WsHandler,
    ) Io.Cancelable!void {
        _ = self;
        const upgrade = raw_request.upgradeRequested();
        const key = switch (upgrade) {
            .websocket => |maybe_key| maybe_key orelse return,
            else => return,
        };

        var socket = raw_request.respondWebSocket(.{ .key = key }) catch return;
        socket.flush() catch return;

        var session = websocket.WebSocketSession{ .ws = &socket };
        handler(&session) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {},
        };
    }
};

fn cancelOrClose(err: ?anyerror) Io.Cancelable!void {
    if (err) |e| {
        if (e == error.Canceled) return error.Canceled;
    }
}

test "HttpServer configuration API without sockets" {
    const expectEqual = std.testing.expectEqual;

    var server = HttpServer.init(std.testing.allocator, .{});
    defer server.deinit();

    try expectEqual(@as(u16, 3000), server.port());

    try expectEqual(@as(usize, 1024 * 1024), server.options.max_request_body_size);
    try expectEqual(@as(usize, 64 * 1024), server.options.max_request_header_size);
    try expectEqual(@as(usize, 10_000), server.options.max_connections);
    // 空闲超时默认禁用（无限等待）。
    try expectEqual(@as(u64, 0), server.options.idle_timeout_ms);

    server.setMaxBodySize(2 * 1024 * 1024);
    server.setMaxHeaderSize(8 * 1024);
    server.setMaxConnections(1234);

    try expectEqual(@as(usize, 2 * 1024 * 1024), server.options.max_request_body_size);
    try expectEqual(@as(usize, 8 * 1024), server.options.max_request_header_size);
    try expectEqual(@as(usize, 1234), server.options.max_connections);

    try expectEqual(@as(usize, 28), HttpServer.recommendedMaxConnections(1));
    try expectEqual(@as(usize, 65_535), HttpServer.recommendedMaxConnections(5000));

    server.setMaxConnections(1);
    try std.testing.expect(server.tryAcquireConnection());
    try std.testing.expect(!server.tryAcquireConnection());
    try expectEqual(@as(usize, 1), server.active_connections.load(.acquire));
    server.releaseConnection();
    try expectEqual(@as(usize, 0), server.active_connections.load(.acquire));
}

test "idleTimeout maps option to zio timeout" {
    var disabled = HttpServer.init(std.testing.allocator, .{});
    defer disabled.deinit();
    try std.testing.expect(disabled.idleTimeout() == .none);

    var enabled = HttpServer.init(std.testing.allocator, .{ .idle_timeout_ms = 5000 });
    defer enabled.deinit();
    const t = enabled.idleTimeout();
    try std.testing.expect(t == .duration);
    try std.testing.expectEqual(@as(u64, 5000), t.duration.toMilliseconds());
}

test "executorOption honors platform and io_threads" {
    var auto_server = HttpServer.init(std.testing.allocator, .{ .io_threads = 0 });
    defer auto_server.deinit();

    var fixed_server = HttpServer.init(std.testing.allocator, .{ .io_threads = 4 });
    defer fixed_server.deinit();

    var huge_server = HttpServer.init(std.testing.allocator, .{ .io_threads = 9999 });
    defer huge_server.deinit();

    if (builtin.os.tag == .windows) {
        // Windows 始终被强制为单执行器。
        try std.testing.expectEqual(ExecutorCount.exact(1), auto_server.executorOption());
        try std.testing.expectEqual(ExecutorCount.exact(1), fixed_server.executorOption());
        try std.testing.expectEqual(ExecutorCount.exact(1), huge_server.executorOption());
    } else {
        // 0 交给 zio 的 CPU 自动检测。
        try std.testing.expectEqual(ExecutorCount.auto, auto_server.executorOption());
        // 显式值原样使用，钳制到支持的范围内。
        try std.testing.expectEqual(ExecutorCount.exact(4), fixed_server.executorOption());
        try std.testing.expectEqual(ExecutorCount.exact(HttpServer.max_executors), huge_server.executorOption());
    }
}

test "HttpServer router and middleware registration" {
    const handler = struct {
        fn ok(_: *http.HttpRequest) !http.HttpResponse {
            return http.HttpResponse.text("ok");
        }
    }.ok;

    const middleware = struct {
        fn inject(_: *http.HttpRequest) anyerror!?http.HttpResponse {
            return null;
        }
    }.inject;

    var server = HttpServer.init(std.testing.allocator, .{});
    defer server.deinit();

    try server.use(middleware);
    try server.router().get("/", handler);

    try std.testing.expectEqual(@as(usize, 1), server.router().routeCount());

    var req: http.HttpRequest = .{
        .allocator = std.testing.allocator,
        .method = .get,
        .path = "/",
        .target = "/",
    };
    const response = try server.router().dispatch(&req);
    try std.testing.expectEqualStrings("ok", response.body);
}

test "enableOpenApi generates and caches a document" {
    const handler = struct {
        fn ok(_: *http.HttpRequest) !http.HttpResponse {
            return http.HttpResponse.text("ok");
        }
    }.ok;

    var server = HttpServer.init(std.testing.allocator, .{});
    defer server.deinit();

    try server.router().get("/users", handler);
    try server.router().get("/users/{id}", handler);
    try server.enableOpenApi(.{ .title = "Smoke API", .version = "9.9.9" });

    try std.testing.expect(server.openapi_json != null);
    const json = server.openapi_json.?;

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("3.0.3", parsed.value.object.get("openapi").?.string);
    try std.testing.expectEqualStrings("Smoke API", parsed.value.object.get("info").?.object.get("title").?.string);
    try std.testing.expect(parsed.value.object.get("paths").?.object.get("/users") != null);

    // 重新启用会替换缓存文档且不泄漏。
    try server.enableOpenApi(.{ .title = "Replaced" });
    const parsed2 = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, server.openapi_json.?, .{});
    defer parsed2.deinit();
    try std.testing.expectEqualStrings("Replaced", parsed2.value.object.get("info").?.object.get("title").?.string);
}

test "setErrorHandler maps service errors to HTTP responses" {
    const ErrorState = struct {
        seen_error: ?anyerror = null,
        seen_path: []const u8 = "",
    };

    const mapper = struct {
        fn handle(ctx: ?*anyopaque, req: *http.HttpRequest, err: anyerror) anyerror!http.HttpResponse {
            const state: *ErrorState = @ptrCast(@alignCast(ctx.?));
            state.seen_error = err;
            state.seen_path = req.path;
            return switch (err) {
                error.Unauthorized => .{ .status = .unauthorized, .body = "Unauthorized" },
                error.Forbidden => .{ .status = .forbidden, .body = "Forbidden" },
                else => http.HttpResponse.serverError(),
            };
        }
    }.handle;

    var state = ErrorState{};
    var server = HttpServer.init(std.testing.allocator, .{});
    defer server.deinit();
    server.setErrorHandler(&state, mapper);

    const handler = struct {
        fn private(_: *http.HttpRequest) anyerror!http.HttpResponse {
            return error.Unauthorized;
        }
    }.private;
    try server.router().get("/private", handler);

    var req: http.HttpRequest = .{
        .allocator = std.testing.allocator,
        .method = .get,
        .path = "/private",
        .target = "/private",
    };

    const response = server.middleware_.execute(&server.router_, &req) catch |err| server.handleError(&req, err);
    try std.testing.expectEqual(http.HttpStatus.unauthorized, response.status);
    try std.testing.expectEqualStrings("Unauthorized", response.body);
    try std.testing.expectEqual(error.Unauthorized, state.seen_error.?);
    try std.testing.expectEqualStrings("/private", state.seen_path);
}

test "error handler failure falls back to 500" {
    const mapper = struct {
        fn handle(_: ?*anyopaque, _: *http.HttpRequest, _: anyerror) anyerror!http.HttpResponse {
            return error.MapperFailed;
        }
    }.handle;

    var server = HttpServer.init(std.testing.allocator, .{});
    defer server.deinit();
    server.setErrorHandler(null, mapper);

    var req: http.HttpRequest = .{
        .allocator = std.testing.allocator,
        .method = .get,
        .path = "/boom",
        .target = "/boom",
    };

    const response = server.handleError(&req, error.Boom);
    try std.testing.expectEqual(http.HttpStatus.internal_server_error, response.status);
    try std.testing.expectEqualStrings("Internal Server Error", response.body);
}

const TypedTestBody = struct { name: []const u8, count: u32 };
const TypedTestReply = struct { greeting: []const u8, count: u32 };

fn typedTestHandler(req: *http.HttpRequest, body: TypedTestBody) !TypedTestReply {
    _ = req;
    return .{ .greeting = body.name, .count = body.count + 1 };
}

test "postJson registers a typed route that parses body and serializes reply" {
    var server = HttpServer.init(std.testing.allocator, .{});
    defer server.deinit();

    try server.postJson("/greet", typedTestHandler, .{ .summary = "Greet" });
    try std.testing.expectEqual(@as(usize, 1), server.router().routeCount());

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = http.HttpRequest.initParsed(arena.allocator(), "POST", "/greet", "application/json", null, true);
    defer req.deinit();
    req.body_bytes =
        \\{"name":"zig","count":4}
    ;

    const res = try server.router().dispatch(&req);
    try std.testing.expectEqual(http.HttpStatus.ok, res.status);
    try std.testing.expectEqualStrings("application/json", res.content_type);
    try std.testing.expectEqualStrings("{\"greeting\":\"zig\",\"count\":5}", res.body);
}

test "enableOpenApi reflects typed route request and response schemas" {
    var server = HttpServer.init(std.testing.allocator, .{});
    defer server.deinit();

    try server.postJson("/greet", typedTestHandler, .{ .summary = "Greet" });
    try server.enableOpenApi(.{ .title = "Typed API" });

    const json = server.openapi_json.?;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    const op = parsed.value.object.get("paths").?.object
        .get("/greet").?.object
        .get("post").?.object;

    // 请求体 schema 反射出 TypedTestBody。
    const req_props = op.get("requestBody").?.object
        .get("content").?.object
        .get("application/json").?.object
        .get("schema").?.object
        .get("properties").?.object;
    try std.testing.expect(req_props.get("name") != null);
    try std.testing.expect(req_props.get("count") != null);

    // 响应 schema 反射出 TypedTestReply。
    const resp_props = op.get("responses").?.object
        .get("200").?.object
        .get("content").?.object
        .get("application/json").?.object
        .get("schema").?.object
        .get("properties").?.object;
    try std.testing.expect(resp_props.get("greeting") != null);
    try std.testing.expect(resp_props.get("count") != null);
}

// --- 优雅关闭 -------------------------------------------------------

const ShutdownTestState = struct {
    server: *HttpServer,
    io: Io,
    err: ?anyerror = null,
    served_status: ?http.HttpStatus = null,
};

/// 镜像 `HttpServer.start`，但绑定一个临时端口，并通过 `state` 把绑定地址
/// 报告回去，以便测试客户端连接。并发运行 accept 循环，然后等待关闭信号
/// 并排空。
fn shutdownServerMain(state: *ShutdownTestState) anyerror!void {
    const self = state.server;
    const io = state.io;

    const addr = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    // 为客户端发布实际绑定的端口（端口 0 -> 由操作系统分配）。
    self.options.port = listener.socket.address.getPort();

    var group: Io.Group = .init;
    self.accepting.store(true, .release);
    var accept_future = io.async(HttpServer.acceptLoop, .{ self, io, &listener, &group });

    self.shutdown_event.waitUncancelable(io);

    self.accepting.store(false, .release);
    _ = accept_future.cancel(io);
    group.await(io) catch {};
}

fn shutdownClientMain(state: *ShutdownTestState) anyerror!void {
    const self = state.server;
    const io = state.io;

    // 等待服务器开始接收且已绑定端口。
    while (!self.isAccepting() or self.options.port == 0) {
        try io.sleep(.fromMilliseconds(1), .awake);
    }

    // 通过 loopback 发送一个真实请求，然后优雅关闭。
    const addr = try Io.net.IpAddress.parseIp4("127.0.0.1", self.options.port);
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var wbuf: [256]u8 = undefined;
    var writer = stream.writer(io, &wbuf);
    try writer.interface.writeAll("GET /ping HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    try writer.interface.flush();

    var rbuf: [1024]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    // 读取状态行；容忍短读。
    var line_buf: [64]u8 = undefined;
    const n = reader.interface.readSliceShort(&line_buf) catch 0;
    if (n > 0 and std.mem.indexOf(u8, line_buf[0..n], "200") != null) {
        state.served_status = .ok;
    }

    // 请求优雅关闭；服务器 fiber 排空后返回。
    self.requestShutdown(io);
}

fn shutdownTestRoot(state: *ShutdownTestState) anyerror!void {
    const io = state.io;
    var group: Io.Group = .init;
    const Wrap = struct {
        fn server(s: *ShutdownTestState) Io.Cancelable!void {
            shutdownServerMain(s) catch |e| {
                s.err = e;
            };
        }
        fn client(s: *ShutdownTestState) Io.Cancelable!void {
            shutdownClientMain(s) catch |e| {
                if (s.err == null) s.err = e;
            };
        }
    };
    try group.concurrent(io, Wrap.server, .{state});
    try group.concurrent(io, Wrap.client, .{state});
    group.await(io) catch {};
    if (state.err) |e| return e;
}

fn pingHandler(_: *http.HttpRequest) !http.HttpResponse {
    return http.HttpResponse.text("pong");
}

test "requestShutdown stops accepting and drains in-flight handlers" {
    var runtime = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();

    var server = HttpServer.init(std.testing.allocator, .{ .host = "127.0.0.1", .port = 0 });
    defer server.deinit();
    try server.router().get("/ping", pingHandler);

    var state = ShutdownTestState{ .server = &server, .io = runtime.io() };
    try shutdownTestRoot(&state);

    // 请求已被处理，且服务器不再接收新连接。
    try std.testing.expectEqual(http.HttpStatus.ok, state.served_status orelse return error.NoResponse);
    try std.testing.expect(!server.isAccepting());
}

// --- FileBody 流式发送端到端 ---------------------------------------

const FileBodyTestState = struct {
    io: Io,
    port: u16 = 0,
    ready: std.atomic.Value(bool) = .init(false),
    file_path: []const u8,
    file_len: u64,
    body_ok: bool = false,
    status_ok: bool = false,
    err: ?anyerror = null,
};

/// 接受一个 loopback 连接，接收请求头，并通过 `respondWithIo` 以文件支撑
/// 的响应体回复。
fn fileBodyServerMain(state: *FileBodyTestState) anyerror!void {
    const io = state.io;

    const addr = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    state.port = listener.socket.address.getPort();
    state.ready.store(true, .release);

    const stream = try listener.accept(io);
    defer stream.close(io);

    var rbuf: [4096]u8 = undefined;
    var reader = zio.net.Stream.Reader.fromStd(stream, io, &rbuf);
    var wbuf: [4096]u8 = undefined;
    var writer = zio.net.Stream.Writer.fromStd(stream, io, &wbuf);
    var raw_server = std.http.Server.init(&reader.interface, &writer.interface);

    var raw_request = try raw_server.receiveHead();
    const res = http.HttpResponse.fileBody(.ok, "text/plain", state.file_path, 0, state.file_len);
    try res.respondWithIo(&raw_request, io);
}

fn fileBodyClientMain(state: *FileBodyTestState) anyerror!void {
    const io = state.io;
    while (!state.ready.load(.acquire)) {
        try io.sleep(.fromMilliseconds(1), .awake);
    }

    const addr = try Io.net.IpAddress.parseIp4("127.0.0.1", state.port);
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var wbuf: [256]u8 = undefined;
    var writer = stream.writer(io, &wbuf);
    try writer.interface.writeAll("GET /file HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    try writer.interface.flush();

    var rbuf: [4096]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    var acc: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < acc.len) {
        const n = reader.interface.readSliceShort(acc[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    const response = acc[0..total];
    if (std.mem.indexOf(u8, response, "200") != null) state.status_ok = true;
    // 响应体跟在空行之后；文件内容为 "Hello, FileBody!"。
    if (std.mem.indexOf(u8, response, "Hello, FileBody!") != null) state.body_ok = true;
}

fn fileBodyTestRoot(state: *FileBodyTestState) anyerror!void {
    const io = state.io;
    var group: Io.Group = .init;
    const Wrap = struct {
        fn server(s: *FileBodyTestState) Io.Cancelable!void {
            fileBodyServerMain(s) catch |e| {
                if (s.err == null) s.err = e;
            };
        }
        fn client(s: *FileBodyTestState) Io.Cancelable!void {
            fileBodyClientMain(s) catch |e| {
                if (s.err == null) s.err = e;
            };
        }
    };
    try group.concurrent(io, Wrap.server, .{state});
    try group.concurrent(io, Wrap.client, .{state});
    group.await(io) catch {};
    if (state.err) |e| return e;
}

fn fileBodyTestMain(state: *FileBodyTestState) Io.Cancelable!void {
    fileBodyTestRoot(state) catch |e| {
        if (state.err == null) state.err = e;
    };
}

test "respondWithIo streams a file-backed body over loopback" {
    var runtime = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();
    const io = runtime.io();

    const payload = "Hello, FileBody!";
    const path = "zig-cache-zyra-filebody-smoke.txt";

    // 用同一个 respondWithIo 读取所用的 std.Io 后端创建临时文件。
    {
        var dir = std.Io.Dir.cwd();
        var f = try dir.createFile(io, path, .{});
        try f.writePositionalAll(io, payload, 0);
        f.close(io);
    }
    defer {
        var dir = std.Io.Dir.cwd();
        dir.deleteFile(io, path) catch {};
    }

    var state = FileBodyTestState{ .io = io, .file_path = path, .file_len = payload.len };
    var root = io.async(fileBodyTestMain, .{&state});
    root.await(io) catch {};
    if (state.err) |e| return e;

    try std.testing.expect(state.status_ok);
    try std.testing.expect(state.body_ok);
}

// --- onReady 启动钩子 -------------------------------------------------

const OnReadyState = struct {
    called: bool = false,
    io_was_usable: bool = false,
};

test "onReady hook runs inside the runtime before accepting" {
    var server = HttpServer.init(std.testing.allocator, .{ .host = "127.0.0.1", .port = 0 });
    defer server.deinit();

    var state = OnReadyState{};
    // 钩子在 accept 之前运行；为了让 start 能返回，钩子内通过 ctx 拿到
    // server 并请求关闭。这里用一个包装把 server 与 state 一起传入。
    const HookCtx = struct {
        server: *HttpServer,
        state: *OnReadyState,
        fn run(ctx: ?*anyopaque, io: Io) anyerror!void {
            const c: *@This() = @ptrCast(@alignCast(ctx.?));
            c.state.called = true;
            _ = std.Io.Clock.now(.awake, io).nanoseconds;
            c.state.io_was_usable = true;
            // 预置关闭信号：钩子返回后 start 开始 accept，随即在 shutdown
            // 事件上立刻被唤醒并干净返回。
            c.server.requestShutdown(io);
        }
    };
    var hook_ctx = HookCtx{ .server = &server, .state = &state };
    server.onReady(&hook_ctx, HookCtx.run);

    try server.start();

    try std.testing.expect(state.called);
    try std.testing.expect(state.io_was_usable);
    try std.testing.expect(!server.isAccepting());
}
