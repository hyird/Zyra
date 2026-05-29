//! 中间件示例：洋葱模型中间件、CORS、会话。
//!
//! 运行：`zig build run-middleware`（监听 3000 端口）
//!
//! 试一试：
//!   curl -i http://localhost:3000/                       # 看自定义响应头
//!   curl -i http://localhost:3000/visits                 # 看 Set-Cookie，多刷几次看计数
//!   curl -i -X OPTIONS http://localhost:3000/ \
//!     -H 'Origin: http://example.com' \
//!     -H 'Access-Control-Request-Method: GET'            # CORS 预检 204

const std = @import("std");
const zyra = @import("zyra");

/// 自定义洋葱中间件：`next.run` 之前是「请求进入」阶段，之后是「响应
/// 返回」阶段。这里在响应上加一个头部。
fn timingHeader(req: *zyra.HttpRequest, next: *zyra.Next) anyerror!zyra.HttpResponse {
    var res = try next.run(req); // 先执行内层（其它中间件 + 处理函数）
    try res.setHeader("x-powered-by", "Zyra");
    return res;
}

fn home(_: *zyra.HttpRequest) !zyra.HttpResponse {
    return zyra.HttpResponse.text("首页\n");
}

/// 读取/更新会话里的访问计数。`SessionMiddleware` 会把 `*Session`
/// 附加到请求上，用 `zyra.session.fromRequest(req)` 取出。
fn visits(req: *zyra.HttpRequest) !zyra.HttpResponse {
    const io = req.io.?;
    const sess = zyra.session.fromRequest(req) orelse
        return zyra.HttpResponse.text("无会话\n");

    const prev = sess.get(io, "visits") orelse "0";
    const n = std.fmt.parseInt(u32, prev, 10) catch 0;
    const next_str = try std.fmt.allocPrint(req.allocator, "{d}", .{n + 1});
    try sess.set(io, "visits", next_str);

    const body = try std.fmt.allocPrint(req.allocator, "访问次数：{d}\n", .{n + 1});
    return zyra.HttpResponse.text(body);
}

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var server = zyra.HttpServer.init(allocator, .{
        .port = 3000,
        .io_threads = 2,
    });
    defer server.deinit();

    // 1) 自定义洋葱中间件。
    try server.useOnion(timingHeader);

    // 2) CORS 中间件（上下文洋葱），通过 attach 接入。
    var cors = try zyra.Cors.init(allocator, .{
        .allowed_origins = &.{"*"},
        .allowed_methods = &.{ "GET", "POST", "OPTIONS" },
        .max_age_seconds = 3600,
    });
    try cors.attach(&server);

    // 3) 会话中间件：解析/下发会话 cookie，并把 *Session 附加到请求。
    var sessions = zyra.SessionManager.init(allocator, .{ .secure = false });
    var session_mw = zyra.SessionMiddleware.init(&sessions);
    try session_mw.attach(&server);

    try server.router().get("/", home);
    try server.router().get("/visits", visits);

    try server.start();
}
