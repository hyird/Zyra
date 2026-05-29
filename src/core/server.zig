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

pub const ServerOptions = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 3000,
    /// Number of zio executors. 0 selects a platform default.
    /// Windows is currently forced to 1 executor to avoid cross-IOCP socket I/O.
    io_threads: usize = 0,
    max_request_header_size: usize = 64 * 1024,
    max_request_body_size: usize = 1024 * 1024,
    max_connections: usize = 10_000,
    write_buffer_size: usize = 4096,
};

pub const HttpServer = struct {
    allocator: std.mem.Allocator,
    options: ServerOptions,
    router_: Router,
    middleware_: MiddlewarePipeline,
    memory_pool: MemoryPool,
    active_connections: std.atomic.Value(usize),
    /// Pre-generated OpenAPI JSON document, served at `openapi_path` when set.
    openapi_json: ?[]const u8 = null,
    openapi_path: []const u8 = "/openapi.json",

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

    pub fn useBeforeAfter(
        self: *HttpServer,
        before: @import("middleware.zig").BeforeHandler,
        after: ?@import("middleware.zig").AfterHandler,
    ) !void {
        try self.middleware_.useBeforeAfter(before, after);
    }

    /// Registers a WebSocket handler for an exact path. The server upgrades
    /// matching requests and runs the handler with a `WebSocketSession`.
    pub fn ws(self: *HttpServer, path: []const u8, handler: @import("router.zig").WsHandler) !void {
        try self.router_.ws(path, handler);
    }

    /// Generates an OpenAPI 3.0.3 document from all currently registered routes
    /// and serves it at `/openapi.json`. Call this after registering routes.
    /// Replaces any previously generated document.
    pub fn enableOpenApi(self: *HttpServer, config: openapi.Config) !void {
        var doc = openapi.OpenApiDocument.init(self.allocator, config);
        defer doc.deinit();
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
        const executor_count = try self.executorCount();
        var runtime = try zio.Runtime.init(self.allocator, .{ .executors = .exact(executor_count) });
        defer runtime.deinit();

        const io = runtime.io();
        const addr = try Io.net.IpAddress.parseIp4(self.options.host, self.options.port);
        var listener = try addr.listen(io, .{ .reuse_address = true });
        defer listener.deinit(io);

        std.log.info("Zyra listening on {f}", .{listener.socket.address});

        var group: Io.Group = .init;
        defer group.cancel(io);

        while (true) {
            const stream = try listener.accept(io);
            errdefer stream.close(io);
            if (!self.tryAcquireConnection()) {
                stream.close(io);
                continue;
            }
            errdefer self.releaseConnection();
            try group.concurrent(io, handleClient, .{ self, io, stream });
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

    fn executorCount(self: *const HttpServer) !u8 {
        if (builtin.os.tag == .windows) return 1;

        const requested = if (self.options.io_threads == 0)
            try std.Thread.getCpuCount()
        else
            self.options.io_threads;
        return @intCast(@min(@max(requested, 1), std.math.maxInt(u8)));
    }

    fn handleClient(self: *HttpServer, io: Io, stream: Io.net.Stream) Io.Cancelable!void {
        defer self.releaseConnection();
        defer stream.close(io);

        const read_buffer = self.allocator.alloc(u8, self.options.max_request_header_size) catch return;
        defer self.allocator.free(read_buffer);
        var reader = stream.reader(io, read_buffer);

        const write_buffer = self.allocator.alloc(u8, self.options.write_buffer_size) catch return;
        defer self.allocator.free(write_buffer);
        var writer = stream.writer(io, write_buffer);

        var raw_server = std.http.Server.init(&reader.interface, &writer.interface);

        while (true) {
            var raw_request = raw_server.receiveHead() catch |err| switch (err) {
                error.ReadFailed => return cancelOrClose(reader.err),
                error.HttpConnectionClosing => return,
                else => return,
            };
            const keep_alive = raw_request.head.keep_alive;

            // WebSocket upgrade: if the client requests an upgrade and a handler
            // is registered for this path, take over the connection.
            if (raw_request.upgradeRequested() == .websocket) {
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

            // Serve the cached OpenAPI document, if enabled.
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

            var response = self.middleware_.execute(&self.router_, &request) catch http.HttpResponse.serverError();
            response.keep_alive = keep_alive;
            response.respond(&raw_request) catch |err| switch (err) {
                error.WriteFailed => return cancelOrClose(writer.err),
                else => return,
            };

            if (!keep_alive) break;
        }
    }

    /// Completes the WebSocket handshake and runs the registered handler.
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

    // Re-enabling replaces the cached document without leaking.
    try server.enableOpenApi(.{ .title = "Replaced" });
    const parsed2 = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, server.openapi_json.?, .{});
    defer parsed2.deinit();
    try std.testing.expectEqualStrings("Replaced", parsed2.value.object.get("info").?.object.get("title").?.string);
}
