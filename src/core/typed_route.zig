//! 类型化路由处理器：编译期 trampoline，使处理器可以接收强类型 JSON 请求体并
//! 返回强类型值，同时仍作为普通 `RouteHandler` 注册到路由器上。
//!
//! 类型化处理器有两种形状：
//!   * `fn(*HttpRequest, Body) E!Response` —— JSON body 解析为 `Body`，
//!     返回值序列化为 JSON 响应。
//!   * `fn(*HttpRequest) E!Response`        —— 无请求体；返回值序列化为 JSON 响应。
//!
//! 两种情况下 `Response` 都可以是 `void`（空 200 响应）。请求体和响应类型会在
//! 编译期恢复，因此同一份信息也能供 OpenAPI schema 反射使用。生成的 trampoline
//! 是具体的 `fn(*HttpRequest) anyerror!HttpResponse`，因此除了手写处理器本来就会
//! 执行的工作（`readJson` + `jsonResponse`）之外，没有运行时分发开销。

const std = @import("std");
const http = @import("http.zig");
const router = @import("router.zig");

/// 类型化处理器请求/响应类型的编译期描述。
/// `Body == void` 表示处理器不接收 JSON 请求体。
/// `Response == void` 表示处理器返回空响应。
pub const TypedInfo = struct {
    Body: type,
    Response: type,
};

/// 反射一个类型化处理器函数，返回其请求/响应类型。若处理器不匹配受支持形状，
/// 则触发 `@compileError`。
pub fn infoOf(comptime handler: anytype) TypedInfo {
    const H = @TypeOf(handler);
    const info = @typeInfo(H);
    if (info != .@"fn") @compileError("typed handler must be a function");
    const fn_info = info.@"fn";

    const params = fn_info.params;
    if (params.len == 0 or params.len > 2) {
        @compileError("typed handler must take (*HttpRequest) or (*HttpRequest, Body)");
    }
    const first = params[0].type orelse
        @compileError("typed handler's first parameter must be *HttpRequest");
    if (first != *http.HttpRequest) {
        @compileError("typed handler's first parameter must be *HttpRequest");
    }

    const Body = if (params.len == 2)
        (params[1].type orelse @compileError("typed handler's body parameter must have a concrete type"))
    else
        void;

    const ret = fn_info.return_type orelse
        @compileError("typed handler must return an error union or value");
    const Response = ResponsePayload(ret);

    return .{ .Body = Body, .Response = Response };
}

/// 从处理器返回类型中提取成功负载类型。接受错误联合（`E!T`）或普通值类型
/// （`T`）；`T` 可以是 `void`。
fn ResponsePayload(comptime Ret: type) type {
    return switch (@typeInfo(Ret)) {
        .error_union => |eu| eu.payload,
        else => Ret,
    };
}

/// 为类型化处理器生成一个普通 `RouteHandler` trampoline。该 trampoline 会解析
/// JSON body（当处理器接收 body 时）、调用处理器，并把结果序列化为 JSON 响应
/// （当响应类型为 `void` 时则为空 200）。
pub fn wrap(comptime handler: anytype) router.RouteHandler {
    const ti = comptime infoOf(handler);
    const Body = ti.Body;
    const Response = ti.Response;

    return (struct {
        fn call(req: *http.HttpRequest) anyerror!http.HttpResponse {
            const result = if (Body == void)
                try handler(req)
            else blk: {
                const body = req.readJson(Body) catch
                    return http.HttpResponse.badRequest("Invalid JSON body");
                break :blk try handler(req, body);
            };

            if (Response == void) {
                return http.HttpResponse{ .status = .ok, .body = "" };
            }
            return req.jsonResponse(result);
        }
    }).call;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

const Echo = struct { value: u32 };

fn echoHandler(req: *http.HttpRequest, body: Echo) !Echo {
    _ = req;
    return .{ .value = body.value + 1 };
}

fn noBodyHandler(req: *http.HttpRequest) !Echo {
    _ = req;
    return .{ .value = 7 };
}

fn voidHandler(req: *http.HttpRequest, body: Echo) !void {
    _ = req;
    _ = body;
}

test "infoOf reflects body and response types" {
    const a = comptime infoOf(echoHandler);
    try testing.expect(a.Body == Echo);
    try testing.expect(a.Response == Echo);

    const b = comptime infoOf(noBodyHandler);
    try testing.expect(b.Body == void);
    try testing.expect(b.Response == Echo);

    const c = comptime infoOf(voidHandler);
    try testing.expect(c.Body == Echo);
    try testing.expect(c.Response == void);
}

test "wrap parses body and serializes response" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var req = http.HttpRequest.initParsed(arena.allocator(), "POST", "/echo", "application/json", null, true);
    defer req.deinit();
    req.body_bytes =
        \\{"value":41}
    ;

    const handler = wrap(echoHandler);
    const res = try handler(&req);
    try testing.expectEqual(http.HttpStatus.ok, res.status);
    try testing.expectEqualStrings("application/json", res.content_type);
    try testing.expectEqualStrings("{\"value\":42}", res.body);
}

test "wrap rejects malformed JSON with 400" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var req = http.HttpRequest.initParsed(arena.allocator(), "POST", "/echo", "application/json", null, true);
    defer req.deinit();
    req.body_bytes = "not json";

    const handler = wrap(echoHandler);
    const res = try handler(&req);
    try testing.expectEqual(http.HttpStatus.bad_request, res.status);
}

test "wrap handles no-body handler" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var req = http.HttpRequest.initParsed(arena.allocator(), "GET", "/seven", null, null, true);
    defer req.deinit();

    const handler = wrap(noBodyHandler);
    const res = try handler(&req);
    try testing.expectEqual(http.HttpStatus.ok, res.status);
    try testing.expectEqualStrings("{\"value\":7}", res.body);
}

test "wrap returns empty 200 for void response" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var req = http.HttpRequest.initParsed(arena.allocator(), "POST", "/void", "application/json", null, true);
    defer req.deinit();
    req.body_bytes =
        \\{"value":1}
    ;

    const handler = wrap(voidHandler);
    const res = try handler(&req);
    try testing.expectEqual(http.HttpStatus.ok, res.status);
    try testing.expectEqualStrings("", res.body);
}
