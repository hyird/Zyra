const std = @import("std");
const zio = @import("zio");

const http = @import("http.zig");
const Router = @import("router.zig").Router;
const MiddlewarePipeline = @import("middleware.zig").MiddlewarePipeline;
const MemoryPool = @import("memory_pool.zig").MemoryPool;

pub const ServerOptions = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 3000,
    io_threads: usize = 1,
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
        const executor_count: u8 = @intCast(@max(self.options.io_threads, 1));
        const runtime = try zio.Runtime.init(self.allocator, .{ .executors = .exact(executor_count) });
        defer runtime.deinit();

        const addr = try zio.net.IpAddress.parseIp4(self.options.host, self.options.port);
        const listener = try addr.listen(.{});
        defer listener.close();

        std.log.info("Zyra listening on {f}", .{listener.socket.address});

        var group: zio.Group = .init;
        defer group.cancel();

        while (true) {
            const stream = try listener.accept(.{});
            errdefer stream.close();
            try group.spawn(handleClient, .{ self, stream });
        }
    }

    fn handleClient(self: *HttpServer, stream: zio.net.Stream) !void {
        defer stream.close();
        defer stream.shutdown(.both) catch {};

        const read_buffer = try self.allocator.alloc(u8, self.options.max_request_header_size);
        defer self.allocator.free(read_buffer);
        var reader = stream.reader(read_buffer);

        const write_buffer = try self.allocator.alloc(u8, self.options.write_buffer_size);
        defer self.allocator.free(write_buffer);
        var writer = stream.writer(write_buffer);

        var raw_server = std.http.Server.init(&reader.interface, &writer.interface);

        while (true) {
            var raw_request = raw_server.receiveHead() catch |err| switch (err) {
                error.ReadFailed => return reader.err orelse err,
                error.HttpConnectionClosing => return,
                else => return err,
            };

            var arena = self.memory_pool.requestArena();
            defer arena.deinit();

            var request = http.HttpRequest.init(arena.allocator(), raw_request.head);
            defer request.deinit();

            var response = self.middleware_.execute(&self.router_, &request) catch http.HttpResponse.serverError();
            response.keep_alive = raw_request.head.keep_alive;
            try response.respond(&raw_request);

            if (!raw_request.head.keep_alive) break;
        }
    }
};
