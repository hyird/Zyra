//! 日志示例：异步文件日志 sink（AsyncFileSink）+ 请求日志中间件。
//!
//! 运行：`zig build run-logging`（监听 3000 端口，日志写入 ./zyra.log）
//!
//! 试一试：
//!   curl http://localhost:3000/
//!   curl http://localhost:3000/slow
//!   然后查看 ./zyra.log，每行一条请求日志（方法/路径/状态/耗时）。
//!
//! 要点：`AsyncFileSink`/`FileSink` 需要 `std.Io` 才能打开文件，而
//! `HttpServer` 在内部自管 zio 运行时。因此用 `server.onReady` 启动钩子
//! 在运行时就绪、开始 accept 之前打开并启动 sink——这是把依赖 io 的资源
//! 接入 server 的标准方式。

const std = @import("std");
const zyra = @import("zyra");

/// 把需要在启动钩子里初始化、并在整个进程生命周期里存活的状态集中起来。
const AppLog = struct {
    allocator: std.mem.Allocator,
    sink: zyra.AsyncFileSink = undefined,
    logger: zyra.Logger = undefined,
    started: bool = false,

    /// 启动钩子：在 zio 运行时的 fiber 内、accept 之前被调用，拿到可用的
    /// `io`。这里打开异步文件 sink、启动其后台刷盘 fiber，并填充 logger。
    fn onReady(ctx: ?*anyopaque, io: std.Io) anyerror!void {
        const self: *AppLog = @ptrCast(@alignCast(ctx.?));
        self.sink = try zyra.AsyncFileSink.open(self.allocator, io, "zyra.log", .{
            .truncate = true,
            .flush_interval_ms = 200,
        });
        self.sink.start(io); // 启动后台批量刷盘 fiber
        self.logger = zyra.Logger.init(self.sink.sink(), .info);
        self.started = true;
    }
};

fn home(_: *zyra.HttpRequest) !zyra.HttpResponse {
    return zyra.HttpResponse.text("看 ./zyra.log\n");
}

/// 故意慢一点，让请求日志里的耗时（dur_us）更明显。
fn slow(req: *zyra.HttpRequest) !zyra.HttpResponse {
    if (req.io) |io| io.sleep(.fromMilliseconds(20), .awake) catch {};
    return zyra.HttpResponse.text("慢响应\n");
}

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var server = zyra.HttpServer.init(allocator, .{
        .port = 3000,
        .io_threads = 2,
    });
    defer server.deinit();

    var app = AppLog{ .allocator = allocator };

    // 注册启动钩子：sink 与 logger 都在钩子内（运行时上下文中）初始化。
    server.onReady(&app, AppLog.onReady);

    // 请求日志中间件持有 logger 指针；它在每个请求里被解引用，那时钩子
    // 早已把 logger 填好。LogMiddleware 用 req.io 的时钟测量请求耗时。
    var log_mw = zyra.LogMiddleware.init(&app.logger);
    try log_mw.attach(&server);

    try server.router().get("/", home);
    try server.router().get("/slow", slow);

    try server.start();
}
