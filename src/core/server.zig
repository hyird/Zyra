const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");
const Io = std.Io;

const http = @import("http.zig");
const native_http = @import("native_http.zig");
const Router = @import("router.zig").Router;
const MiddlewarePipeline = @import("middleware.zig").MiddlewarePipeline;
const MemoryPool = @import("memory_pool.zig").MemoryPool;

pub const ServerOptions = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 3000,
    /// Number of zio executors. 0 selects a platform default.
    /// Windows is currently forced to 1 executor to avoid cross-IOCP socket I/O.
    io_threads: usize = 0,
    max_request_header_size: usize = 8 * 1024,
    max_request_body_size: u64 = 1024 * 1024,
    max_connections: usize = 10_000,
    idle_timeout_ms: i64 = 60_000,
    /// 0 means unlimited, matching Hical's connection loop behavior.
    max_keep_alive_requests: usize = 0,
    write_buffer_size: usize = 4096,
};

pub const HttpServer = struct {
    allocator: std.mem.Allocator,
    options: ServerOptions,
    router_: Router,
    middleware_: MiddlewarePipeline,
    memory_pool: MemoryPool,
    active_connections: std.atomic.Value(usize),
    idle_tracker: IdleTracker,

    pub fn init(allocator: std.mem.Allocator, options: ServerOptions) HttpServer {
        return .{
            .allocator = allocator,
            .options = options,
            .router_ = Router.init(allocator),
            .middleware_ = MiddlewarePipeline.init(allocator),
            .memory_pool = MemoryPool.init(allocator),
            .active_connections = .init(0),
            .idle_tracker = .{},
        };
    }

    pub fn deinit(self: *HttpServer) void {
        self.middleware_.deinit();
        self.router_.deinit();
    }

    pub fn router(self: *HttpServer) *Router {
        return &self.router_;
    }

    pub fn use(self: *HttpServer, middleware: @import("middleware.zig").Middleware) !void {
        try self.middleware_.use(middleware);
    }

    pub fn start(self: *HttpServer) !void {
        // zio's current Windows IOCP backend associates accepted sockets with
        // the accepting executor's event loop. Keep socket reads/writes on that
        // same executor until zio supports cross-executor socket I/O safely.
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
        if (self.options.idle_timeout_ms > 0) {
            try group.concurrent(io, scanIdleConnections, .{ self, io });
        }

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

        var idle_entry: IdleTracker.Entry = .{ .stream = stream, .last_active_ms = .init(nowMs(io)) };
        if (self.options.idle_timeout_ms > 0) self.idle_tracker.register(io, &idle_entry);
        defer if (self.options.idle_timeout_ms > 0) self.idle_tracker.unregister(io, &idle_entry);

        var io_read_buffer: [4096]u8 = undefined;
        var reader = stream.reader(io, &io_read_buffer);

        var request_buffer: [64 * 1024]u8 = undefined;
        var session_buffer: native_http.SessionBuffer = .{ .buf = &request_buffer };

        var write_buffer: [4096]u8 = undefined;
        var writer = stream.writer(io, &write_buffer);

        var requests_handled: usize = 0;
        while (true) {
            const parsed = session_buffer.readHead(&reader.interface, self.options.max_request_header_size) catch |err| switch (err) {
                error.EndOfStream => return,
                error.HeaderTooLarge => {
                    native_http.writeError(&writer.interface, .request_header_fields_too_large, "Request header too large");
                    return;
                },
                error.MalformedRequest => {
                    native_http.writeError(&writer.interface, .bad_request, "Malformed HTTP request");
                    return;
                },
                error.ReadFailed => return cancelOrClose(reader.err),
            };
            idle_entry.touch(io);

            if (parsed.content_length) |content_length| {
                if (content_length > self.options.max_request_body_size) {
                    native_http.writeError(&writer.interface, .payload_too_large, "Request body too large");
                    return;
                }
            }

            requests_handled += 1;
            const keep_alive = parsed.keep_alive and
                (self.options.max_keep_alive_requests == 0 or requests_handled < self.options.max_keep_alive_requests) and
                requestBodyReusable(&session_buffer, parsed);

            {
                var arena = self.memory_pool.requestArena();
                defer arena.deinit();

                var request = http.HttpRequest.initParsed(
                    arena.allocator(),
                    parsed.method,
                    parsed.target,
                    parsed.content_type,
                    parsed.content_length,
                    parsed.keep_alive,
                );
                defer request.deinit();

                var response = self.middleware_.execute(&self.router_, &request) catch http.HttpResponse.serverError();
                response.keep_alive = keep_alive;
                const skip_body = request.method == .head;
                native_http.writeResponse(&writer.interface, response, keep_alive, skip_body) catch {
                    return cancelOrClose(writer.err);
                };
            }
            idle_entry.touch(io);

            if (!keep_alive) break;

            consumeReusableRequest(&session_buffer, parsed);
        }
    }
};

fn scanIdleConnections(self: *HttpServer, io: Io) Io.Cancelable!void {
    const interval_ms = @max(@divTrunc(self.options.idle_timeout_ms, 4), 1000);
    while (true) {
        try Io.Timeout.sleep(.{ .duration = .{ .raw = .fromMilliseconds(interval_ms), .clock = .awake } }, io);
        self.idle_tracker.closeExpired(io, self.options.idle_timeout_ms);
    }
}

const IdleTracker = struct {
    const List = std.DoublyLinkedList;

    const Entry = struct {
        node: List.Node = .{},
        stream: Io.net.Stream,
        last_active_ms: std.atomic.Value(i64),

        fn touch(self: *Entry, io: Io) void {
            self.last_active_ms.store(nowMs(io), .monotonic);
        }
    };

    mutex: Io.Mutex = .init,
    list: List = .{},

    fn register(self: *IdleTracker, io: Io, entry: *Entry) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        entry.touch(io);
        self.list.append(&entry.node);
    }

    fn unregister(self: *IdleTracker, io: Io, entry: *Entry) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.list.remove(&entry.node);
    }

    fn closeExpired(self: *IdleTracker, io: Io, timeout_ms: i64) void {
        const now = nowMs(io);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var node = self.list.first;
        while (node) |current| {
            node = current.next;
            const entry: *Entry = @fieldParentPtr("node", current);
            if (now - entry.last_active_ms.load(.monotonic) >= timeout_ms) {
                entry.stream.close(io);
            }
        }
    }
};

fn nowMs(io: Io) i64 {
    return Io.Timestamp.now(io, .awake).toMilliseconds();
}

fn requestBodyReusable(session_buffer: *const native_http.SessionBuffer, parsed: native_http.ParsedRequest) bool {
    if (parsed.has_transfer_encoding) return false;

    const content_length = parsed.content_length orelse return true;
    const available = session_buffer.used - parsed.header_bytes;
    return @as(u64, @intCast(available)) >= content_length;
}

fn consumeReusableRequest(session_buffer: *native_http.SessionBuffer, parsed: native_http.ParsedRequest) void {
    const content_length = parsed.content_length orelse {
        session_buffer.consume(parsed.header_bytes);
        return;
    };
    session_buffer.consume(parsed.header_bytes + @as(usize, @intCast(content_length)));
}

fn cancelOrClose(err: ?anyerror) Io.Cancelable!void {
    if (err) |e| {
        if (e == error.Canceled) return error.Canceled;
    }
}
