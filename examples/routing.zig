//! 路由示例：演示静态路由、路径参数、路由组与声明式路由注册。
//!
//! 运行：`zig build run-routing`（监听 3000 端口）
//!
//! 试一试：
//!   curl http://localhost:3000/
//!   curl http://localhost:3000/users/42
//!   curl http://localhost:3000/users/42/profile
//!   curl http://localhost:3000/api/v1/ping
//!   curl http://localhost:3000/api/v1/echo/hello

const std = @import("std");
const zyra = @import("zyra");

// ---- 普通处理函数 ------------------------------------------------------

/// 静态路由处理函数。`RouteHandler` 就是
/// `fn(*HttpRequest) anyerror!HttpResponse` 这个裸函数指针类型。
fn index(_: *zyra.HttpRequest) !zyra.HttpResponse {
    return zyra.HttpResponse.text("Zyra 路由示例\n");
}

/// 路径参数 `{id}` 通过 `req.param("id")` 取出（字符串形式）。
fn user(req: *zyra.HttpRequest) !zyra.HttpResponse {
    const id = req.param("id") orelse "unknown";
    return zyra.HttpResponse.text(id);
}

/// 同一路由里可以有多个参数；这里只读取其中一个作演示。
fn userProfile(req: *zyra.HttpRequest) !zyra.HttpResponse {
    const id = req.param("id") orelse "unknown";
    // 用请求 arena 分配响应体，请求结束时自动释放。
    const body = try std.fmt.allocPrint(req.allocator, "用户 {s} 的资料\n", .{id});
    return zyra.HttpResponse.text(body);
}

// ---- 声明式路由表（meta_routes）---------------------------------------

/// 把一组路由集中声明为一个 `routes` 数组，再用 `registerGroupRoutes`
/// 在编译期一次性展开注册。这是 Hical `HICAL_ROUTES` 宏的类型安全等价物。
const ApiV1 = struct {
    fn ping(_: *zyra.HttpRequest) !zyra.HttpResponse {
        return zyra.HttpResponse.json("{\"pong\":true}");
    }

    fn echo(req: *zyra.HttpRequest) !zyra.HttpResponse {
        const msg = req.param("msg") orelse "";
        return zyra.HttpResponse.text(msg);
    }

    pub const routes = [_]zyra.RouteDef{
        .{ .method = .get, .path = "/ping", .handler = ping },
        .{ .method = .get, .path = "/echo/{msg}", .handler = echo },
    };
};

pub fn main() !void {
    var server = zyra.HttpServer.init(std.heap.smp_allocator, .{
        .port = 3000,
        .io_threads = 2,
    });
    defer server.deinit();

    const r = server.router();

    // 逐个注册的普通路由。
    try r.get("/", index);
    try r.get("/users/{id}", user);
    try r.get("/users/{id}/profile", userProfile);

    // 路由组：所有路由共享 `/api/v1` 前缀，组中间件只作用于组内路由。
    var api = r.group("/api/v1");
    // 声明式注册：把 ApiV1.routes 整张表展开到组上。
    try zyra.registerGroupRoutes(&api, ApiV1);

    try server.start();
}
