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
    max_request_header_size: usize = 64 * 1024,
    write_buffer_size: usize = 4096,
};

pub const HttpServer = struct {
    allocator: std.mem.Allocator,
    options: ServerOptions,
    router_: Router,
    middleware_: MiddlewarePipeline,
    memory_pool: MemoryPool,

    pub fn init(allocator: std.mem.Allocator, options: ServerOptions) HttpServer {
        return .{
            .allocator = allocator,
            .options = options,
            .router_ = Router.init(allocator),
            .middleware_ = MiddlewarePipeline.init(allocator),
            .memory_pool = MemoryPool.init(allocator),
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

        while (true) {
            const stream = try listener.accept(io);
            errdefer stream.close(io);
            try group.concurrent(io, handleClient, .{ self, io, stream });
        }
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
        defer stream.close(io);

        var io_read_buffer: [4096]u8 = undefined;
        var reader = stream.reader(io, &io_read_buffer);

        var request_buffer: [64 * 1024]u8 = undefined;
        var session_buffer: native_http.SessionBuffer = .{ .buf = &request_buffer };

        var write_buffer: [4096]u8 = undefined;
        var writer = stream.writer(io, &write_buffer);

        while (true) {
            const parsed = session_buffer.readHead(&reader.interface, self.options.max_request_header_size) catch |err| switch (err) {
                error.EndOfStream => return,
                error.HeaderTooLarge => {
                    native_http.writeError(&writer.interface, .payload_too_large, "Request header too large");
                    return;
                },
                error.MalformedRequest => {
                    native_http.writeError(&writer.interface, .bad_request, "Malformed HTTP request");
                    return;
                },
                error.ReadFailed => return cancelOrClose(reader.err),
            };

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
            response.keep_alive = false;
            const skip_body = request.method == .head;
            native_http.writeResponse(&writer.interface, response, false, skip_body) catch {
                return cancelOrClose(writer.err);
            };

            // The response advertises `connection: close`; do not wait for a
            // possibly incomplete request body before closing the connection.
            break;
        }
    }
};

fn cancelOrClose(err: ?anyerror) Io.Cancelable!void {
    if (err) |e| {
        if (e == error.Canceled) return error.Canceled;
    }
}
