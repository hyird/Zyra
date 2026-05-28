const std = @import("std");
const zio = @import("zio");

const http = @import("http.zig");
const native_http = @import("native_http.zig");
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
        var session_buffer: native_http.SessionBuffer = .{ .buf = read_buffer };

        while (true) {
            const parsed = session_buffer.readHead(stream, self.options.max_request_header_size) catch |err| switch (err) {
                error.EndOfStream, error.ConnectionResetByPeer, error.ConnectionAborted => return,
                error.HeaderTooLarge => {
                    native_http.writeError(stream, .payload_too_large, "Request header too large");
                    return;
                },
                error.MalformedRequest => {
                    native_http.writeError(stream, .bad_request, "Malformed HTTP request");
                    return;
                },
                else => return err,
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
            response.keep_alive = parsed.keep_alive;
            const skip_body = request.method == .head;
            try native_http.writeResponse(stream, response, parsed.keep_alive, skip_body);

            try discardRequestBody(stream, &session_buffer, parsed);

            if (!parsed.keep_alive) break;
        }
    }
};

fn discardRequestBody(stream: zio.net.Stream, session_buffer: *native_http.SessionBuffer, parsed: native_http.ParsedRequest) !void {
    const content_length = parsed.content_length orelse {
        session_buffer.consume(parsed.header_bytes);
        return;
    };

    const available = session_buffer.used - parsed.header_bytes;
    if (available >= content_length) {
        session_buffer.consume(parsed.header_bytes + @as(usize, @intCast(content_length)));
        return;
    }

    session_buffer.used = 0;
    var remaining = content_length - available;
    var discard_buf: [4096]u8 = undefined;
    while (remaining > 0) {
        const want = @min(discard_buf.len, remaining);
        const n = try stream.read(discard_buf[0..want], .none);
        if (n == 0) return;
        remaining -= n;
    }
}
