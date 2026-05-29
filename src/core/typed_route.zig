//! Typed route handlers: compile-time trampolines that let handlers accept a
//! strongly-typed JSON request body and return a strongly-typed value, while
//! still registering as a plain `RouteHandler` on the router.
//!
//! A typed handler has one of two shapes:
//!   * `fn(*HttpRequest, Body) E!Response` — JSON body parsed into `Body`,
//!     return value serialized as a JSON response.
//!   * `fn(*HttpRequest) E!Response`        — no request body; return value
//!     serialized as a JSON response.
//!
//! In both cases `Response` may be `void` (empty 200 response). The body and
//! response types are recovered at compile time so the same information can feed
//! OpenAPI schema reflection. The generated trampoline is a concrete
//! `fn(*HttpRequest) anyerror!HttpResponse`, so there is no runtime dispatch
//! overhead beyond the work a hand-written handler would already perform
//! (`readJson` + `jsonResponse`).

const std = @import("std");
const http = @import("http.zig");
const router = @import("router.zig");

/// Compile-time description of a typed handler's request/response types.
/// `Body == void` means the handler takes no JSON request body.
/// `Response == void` means the handler returns an empty response.
pub const TypedInfo = struct {
    Body: type,
    Response: type,
};

/// Reflects a typed handler function, returning its request/response types.
/// Triggers a `@compileError` if the handler does not match a supported shape.
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

/// Extracts the success payload type from a handler's return type. Accepts an
/// error union (`E!T`) or a plain value type (`T`); `T` may be `void`.
fn ResponsePayload(comptime Ret: type) type {
    return switch (@typeInfo(Ret)) {
        .error_union => |eu| eu.payload,
        else => Ret,
    };
}

/// Generates a plain `RouteHandler` trampoline for a typed handler. The
/// trampoline parses the JSON body (when the handler takes one), invokes the
/// handler, and serializes the result as a JSON response (or an empty 200 when
/// the response type is `void`).
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
// Tests
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
