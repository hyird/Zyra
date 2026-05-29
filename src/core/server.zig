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

/// Records a typed route's OpenAPI metadata. `register` is a compile-time
/// generated function that adds the route's reflected request/response schemas
/// to a document; the `Request`/`Response` types are captured inside it, so no
/// runtime type information needs to be stored.
const TypedRouteRecord = struct {
    method: http.HttpMethod,
    path: []const u8,
    summary: []const u8,
    register: *const fn (*openapi.OpenApiDocument, http.HttpMethod, []const u8, []const u8) anyerror!void,
};

/// zio's `ExecutorCount` type, recovered from `Runtime.init`'s options
/// parameter since the root `zio` module does not re-export it directly.
const RuntimeOptions = @typeInfo(@TypeOf(zio.Runtime.init)).@"fn".params[1].type.?;
const ExecutorCount = @FieldType(RuntimeOptions, "executors");

pub const ServerOptions = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 3000,
    /// Number of zio executors (I/O threads). 0 lets zio auto-detect based on
    /// the CPU count. Windows is forced to a single executor to avoid
    /// cross-IOCP socket I/O.
    io_threads: usize = 0,
    max_request_header_size: usize = 64 * 1024,
    max_request_body_size: usize = 1024 * 1024,
    max_connections: usize = 10_000,
    write_buffer_size: usize = 4096,
    /// Idle (keep-alive) timeout in milliseconds. While waiting for the next
    /// request head on a kept-alive connection, the socket read is bounded by
    /// this deadline; if no data arrives in time the connection is closed.
    /// 0 disables the timeout (wait indefinitely). The timeout only applies to
    /// the wait between requests, not to in-flight request processing.
    idle_timeout_ms: u64 = 0,
};

pub const HttpServer = struct {
    allocator: std.mem.Allocator,
    options: ServerOptions,
    router_: Router,
    middleware_: MiddlewarePipeline,
    memory_pool: MemoryPool,
    active_connections: std.atomic.Value(usize),
    /// Signaled by `requestShutdown` to begin a graceful shutdown: the accept
    /// loop stops taking new connections and in-flight handlers are drained
    /// before `start` returns. Threadsafe; safe to set from another thread.
    shutdown_event: std.Io.Event = .unset,
    /// Set once the accept loop stops taking new connections, so handlers (and
    /// tests) can observe that draining is underway.
    accepting: std.atomic.Value(bool) = .init(false),
    /// Pre-generated OpenAPI JSON document, served at `openapi_path` when set.
    openapi_json: ?[]const u8 = null,
    openapi_path: []const u8 = "/openapi.json",
    /// OpenAPI metadata for routes registered through the typed JSON helpers
    /// (`getJson`/`postJson`/...). Used by `enableOpenApi` to emit reflected
    /// request/response schemas.
    typed_routes: std.ArrayListUnmanaged(TypedRouteRecord) = .empty,

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

    /// Registers a context-carrying onion middleware (e.g. CORS, sessions).
    /// `context` must outlive the server.
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

    /// Registers a WebSocket handler for an exact path. The server upgrades
    /// matching requests and runs the handler with a `WebSocketSession`.
    pub fn ws(self: *HttpServer, path: []const u8, handler: @import("router.zig").WsHandler) !void {
        try self.router_.ws(path, handler);
    }

    /// Options for the typed JSON route helpers.
    pub const JsonRouteOptions = struct {
        summary: []const u8 = "",
    };

    /// Registers a typed JSON route. `handler` is a function of the form
    /// `fn(*HttpRequest, Body) E!Response` or `fn(*HttpRequest) E!Response`,
    /// where `Body`/`Response` are Zig types. The framework parses the JSON body
    /// into `Body` (responding 400 on malformed JSON), invokes the handler, and
    /// serializes the returned value as a JSON response (`void` yields an empty
    /// 200). The request/response types are reflected into OpenAPI schemas when
    /// `enableOpenApi` is called.
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

    /// Generates an OpenAPI 3.0.3 document from all currently registered routes
    /// and serves it at `/openapi.json`. Call this after registering routes.
    /// Replaces any previously generated document.
    pub fn enableOpenApi(self: *HttpServer, config: openapi.Config) !void {
        var doc = openapi.OpenApiDocument.init(self.allocator, config);
        defer doc.deinit();
        // Typed JSON routes first so their reflected schemas are recorded;
        // `collectFromRouter` then fills in any remaining plain routes without
        // overwriting them.
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

        // In-flight connection handlers live in this group. On shutdown we
        // `await` (not `cancel`) the group so active requests finish draining.
        var group: Io.Group = .init;

        self.accepting.store(true, .release);

        // Run the accept loop concurrently so the calling fiber can wait for the
        // shutdown signal. When that signal arrives we cancel the accept loop,
        // which interrupts the blocked `accept` at its next cancelation point.
    var accept_future = io.async(HttpServer.acceptLoop, .{ self, io, &listener, &group });

        // Block until a graceful shutdown is requested (or never, if it isn't).
        self.shutdown_event.waitUncancelable(io);

        // Stop accepting new connections, then drain handlers already running.
        self.accepting.store(false, .release);
        _ = accept_future.cancel(io);
        group.await(io) catch {};
    }

    /// Requests a graceful shutdown: stops accepting new connections and lets
    /// in-flight requests finish before `start` returns. Threadsafe; may be
    /// called from another fiber/thread (e.g. a signal handler bridge).
    pub fn requestShutdown(self: *HttpServer, io: Io) void {
        self.shutdown_event.set(io);
    }

    /// True while the server is still accepting new connections. Becomes false
    /// once a graceful shutdown has begun.
    pub fn isAccepting(self: *const HttpServer) bool {
        return self.accepting.load(.acquire);
    }

    /// Accept loop, run as a cancelable task. Cancellation (triggered by
    /// `requestShutdown`) surfaces as `error.Canceled` from `accept`, which ends
    /// the loop without taking further connections.
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

    /// Resolves the zio executor configuration. Windows is forced to a single
    /// executor; elsewhere `io_threads == 0` defers to zio's CPU auto-detection
    /// (`.auto`) and any other value is used verbatim (clamped to the runtime's
    /// supported range).
    fn executorOption(self: *const HttpServer) ExecutorCount {
        if (builtin.os.tag == .windows) return .exact(1);
        if (self.options.io_threads == 0) return .auto;
        const clamped: u8 = @intCast(@min(@max(self.options.io_threads, 1), max_executors));
        return .exact(clamped);
    }

    const max_executors = 64;

    /// Maps the configured `idle_timeout_ms` to a zio read timeout: 0 means no
    /// timeout (wait indefinitely), any other value a millisecond duration.
    fn idleTimeout(self: *const HttpServer) zio.Timeout {
        if (self.options.idle_timeout_ms == 0) return .none;
        return .fromMilliseconds(self.options.idle_timeout_ms);
    }

    fn handleClient(self: *HttpServer, io: Io, stream: Io.net.Stream) Io.Cancelable!void {
        defer self.releaseConnection();
        defer stream.close(io);

        const read_buffer = self.allocator.alloc(u8, self.options.max_request_header_size) catch return;
        defer self.allocator.free(read_buffer);
        var reader = zio.net.Stream.Reader.fromStd(stream, io, read_buffer);

        const write_buffer = self.allocator.alloc(u8, self.options.write_buffer_size) catch return;
        defer self.allocator.free(write_buffer);
        var writer = zio.net.Stream.Writer.fromStd(stream, io, write_buffer);

        var raw_server = std.http.Server.init(&reader.interface, &writer.interface);

        // Idle timeout (if configured) bounds only the wait for the next request
        // head between keep-alive requests. It is armed before `receiveHead` and
        // cleared once a head arrives so in-flight body reads are not affected.
        // zio implements this as a recv + timer completion racing inside the
        // event loop (no extra coroutine), which is the only timeout mechanism
        // that actually fires under epoll/io_uring readiness models.
        const idle_timeout = self.idleTimeout();

        while (true) {
            reader.setTimeout(idle_timeout);
            var raw_request = raw_server.receiveHead() catch |err| switch (err) {
                error.ReadFailed => return cancelOrClose(reader.err),
                error.HttpConnectionClosing => return,
                else => return,
            };
            reader.setTimeout(.none);
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
    // Idle timeout defaults to disabled (wait indefinitely).
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
        // Windows is always forced to a single executor.
        try std.testing.expectEqual(ExecutorCount.exact(1), auto_server.executorOption());
        try std.testing.expectEqual(ExecutorCount.exact(1), fixed_server.executorOption());
        try std.testing.expectEqual(ExecutorCount.exact(1), huge_server.executorOption());
    } else {
        // 0 defers to zio's CPU auto-detection.
        try std.testing.expectEqual(ExecutorCount.auto, auto_server.executorOption());
        // Explicit values are used verbatim, clamped to the supported range.
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

    // Re-enabling replaces the cached document without leaking.
    try server.enableOpenApi(.{ .title = "Replaced" });
    const parsed2 = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, server.openapi_json.?, .{});
    defer parsed2.deinit();
    try std.testing.expectEqualStrings("Replaced", parsed2.value.object.get("info").?.object.get("title").?.string);
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

    // Request body schema reflects TypedTestBody.
    const req_props = op.get("requestBody").?.object
        .get("content").?.object
        .get("application/json").?.object
        .get("schema").?.object
        .get("properties").?.object;
    try std.testing.expect(req_props.get("name") != null);
    try std.testing.expect(req_props.get("count") != null);

    // Response schema reflects TypedTestReply.
    const resp_props = op.get("responses").?.object
        .get("200").?.object
        .get("content").?.object
        .get("application/json").?.object
        .get("schema").?.object
        .get("properties").?.object;
    try std.testing.expect(resp_props.get("greeting") != null);
    try std.testing.expect(resp_props.get("count") != null);
}

// --- Graceful shutdown -------------------------------------------------------

const ShutdownTestState = struct {
    server: *HttpServer,
    io: Io,
    err: ?anyerror = null,
    served_status: ?http.HttpStatus = null,
};

/// Mirrors `HttpServer.start` but binds an ephemeral port and reports the bound
/// address back through `state` so the test client can connect. Runs the accept
/// loop concurrently, then waits for the shutdown signal and drains.
fn shutdownServerMain(state: *ShutdownTestState) anyerror!void {
    const self = state.server;
    const io = state.io;

    const addr = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    // Publish the actual bound port for the client (port 0 -> OS-assigned).
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

    // Wait until the server is accepting and has a bound port.
    while (!self.isAccepting() or self.options.port == 0) {
        try io.sleep(.fromMilliseconds(1), .awake);
    }

    // One real request over loopback, then graceful shutdown.
    const addr = try Io.net.IpAddress.parseIp4("127.0.0.1", self.options.port);
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var wbuf: [256]u8 = undefined;
    var writer = stream.writer(io, &wbuf);
    try writer.interface.writeAll("GET /ping HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    try writer.interface.flush();

    var rbuf: [1024]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    // Read the status line; tolerate short reads.
    var line_buf: [64]u8 = undefined;
    const n = reader.interface.readSliceShort(&line_buf) catch 0;
    if (n > 0 and std.mem.indexOf(u8, line_buf[0..n], "200") != null) {
        state.served_status = .ok;
    }

    // Request graceful shutdown; the server fiber drains and returns.
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

    // The request was served and the server is no longer accepting.
    try std.testing.expectEqual(http.HttpStatus.ok, state.served_status orelse return error.NoResponse);
    try std.testing.expect(!server.isAccepting());
}
