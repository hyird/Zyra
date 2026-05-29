//! 静态文件示例：用带缓存的 `StaticFiles` 服务一个目录。
//!
//! 运行：`zig build run-static`（监听 3000 端口，服务 ./public 目录）
//!
//! 试一试（先在 ./public 下放几个文件）：
//!   curl http://localhost:3000/static/index.html
//!   curl -I http://localhost:3000/static/index.html        # 看 ETag
//!   curl -H 'Range: bytes=0-9' http://localhost:3000/static/index.html
//!
//! 说明：`StaticFiles` 不直接绑定到路由，而是通过一个上下文洋葱中间件
//! 接入——若请求路径命中前缀就交给它处理，否则调用 `next` 继续后续路由。

const std = @import("std");
const zyra = @import("zyra");

/// 上下文中间件：把 `*StaticFiles` 作为上下文，命中前缀则 serve。
/// `serve` 返回 404 时仍交给后续路由（让普通路由有机会处理）。
fn serveStatic(ctx: *anyopaque, req: *zyra.HttpRequest, next: *zyra.Next) anyerror!zyra.HttpResponse {
    const sf: *zyra.StaticFiles = @ptrCast(@alignCast(ctx));
    if (std.mem.startsWith(u8, req.path, "/static/")) {
        const res = try sf.serve(req);
        // 命中文件（包括 304/206）直接返回；404 则回退到后续路由。
        if (res.status != .not_found) return res;
    }
    return next.run(req);
}

fn home(_: *zyra.HttpRequest) !zyra.HttpResponse {
    return zyra.HttpResponse.text("访问 /static/<文件名> 获取静态资源\n");
}

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var server = zyra.HttpServer.init(allocator, .{
        .port = 3000,
        .io_threads = 2,
    });
    defer server.deinit();

    // initCached 启用有界 LRU + TTL 的路径解析缓存：重复请求会跳过
    // path.join + stat，命中时直接复用缓存的磁盘路径/大小/ETag/MIME。
    var static = try zyra.StaticFiles.initCached(allocator, "public", "/static/");
    defer static.deinit(allocator);

    // 把静态文件中间件挂到管线最前面。
    try server.useOnionCtx(&static, serveStatic);

    try server.router().get("/", home);

    try server.start();
}
