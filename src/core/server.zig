const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");
const Io = std.Io;

const http = @import("http.zig");
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

            var arena = self.memory_pool.requestArena();
            defer arena.deinit();

            var request = http.HttpRequest.init(arena.allocator(), raw_request.head);
            defer request.deinit();

            var response = self.middleware_.execute(&self.router_, &request) catch http.HttpResponse.serverError();
            response.keep_alive = raw_request.head.keep_alive;
            response.respond(&raw_request) catch |err| switch (err) {
                error.WriteFailed => return cancelOrClose(writer.err),
                else => return,
            };

            if (!raw_request.head.keep_alive) break;
        }
    }
};

fn cancelOrClose(err: ?anyerror) Io.Cancelable!void {
    if (err) |e| {
        if (e == error.Canceled) return error.Canceled;
    }
}
