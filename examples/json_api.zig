//! 带类型的 JSON API 示例：typed_route + 自动 OpenAPI 文档。
//!
//! 运行：`zig build run-json`（监听 3000 端口）
//!
//! 试一试：
//!   curl -X POST http://localhost:3000/users \
//!     -H 'content-type: application/json' \
//!     -d '{"name":"Ada","age":36}'
//!   curl http://localhost:3000/health
//!   curl http://localhost:3000/openapi.json        # 自动生成的 OpenAPI 文档

const std = @import("std");
const zyra = @import("zyra");

/// 请求体类型：会在编译期被反射成 JSON Schema。
const CreateUser = struct {
    name: []const u8,
    age: u32,
};

/// 响应体类型：同样会被反射进 OpenAPI 文档。
const UserCreated = struct {
    id: u64,
    name: []const u8,
};

/// 带类型的处理函数：`fn(*HttpRequest, Body) E!Response`。
/// 编译期生成的 trampoline 会：把请求体解析为 `CreateUser`（JSON 格式
/// 错误自动返回 400），调用本函数，再把返回值序列化为 JSON 响应。
fn createUser(_: *zyra.HttpRequest, body: CreateUser) !UserCreated {
    // 这里只是回显，真实场景会写库并返回生成的 id。
    return .{ .id = 1001, .name = body.name };
}

/// 无请求体的带类型处理函数：`fn(*HttpRequest) E!Response`。
const Health = struct { status: []const u8 };
fn health(_: *zyra.HttpRequest) !Health {
    return .{ .status = "ok" };
}

pub fn main() !void {
    var server = zyra.HttpServer.init(std.heap.smp_allocator, .{
        .port = 3000,
        .io_threads = 2,
    });
    defer server.deinit();

    // 注册带类型路由。Body/Response 类型会被记录下来供 OpenAPI 使用。
    try server.postJson("/users", createUser, .{ .summary = "创建用户" });
    try server.getJson("/health", health, .{ .summary = "健康检查" });

    // 在注册路由之后启用 OpenAPI：自动收集所有路由并在
    // /openapi.json 暴露 OpenAPI 3.0.3 文档。
    try server.enableOpenApi(.{ .title = "Zyra 示例 API", .version = "1.0.0" });

    try server.start();
}
