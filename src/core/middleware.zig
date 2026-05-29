const std = @import("std");
const http = @import("http.zig");
const router_mod = @import("router.zig");

/// 洋葱模型中间件处理函数。
///
/// 每个处理函数接收请求和一个 `*Next`。调用 `next.run(req)` 会调用链中的
/// 下一个中间件（链耗尽时则进行最终的路由分派）。处理函数可以在 `next.run`
/// 调用前后运行逻辑（洋葱模型），可以不调用 `next` 直接返回响应来短路，
/// 也可以变换 `next` 返回的响应。
pub const MiddlewareHandler = *const fn (*http.HttpRequest, *Next) anyerror!http.HttpResponse;

/// 携带不透明上下文指针的洋葱模型中间件，使有状态中间件（CORS 选项、会话
/// 管理器、日志器）无需堆上闭包即可实现。上下文在注册时通过
/// `useOnionCtx`/`useOnionCtxValue` 提供，并原样回传给处理函数。
pub const ContextHandler = *const fn (*anyopaque, *http.HttpRequest, *Next) anyerror!http.HttpResponse;

/// 同步“before”钩子。返回响应会短路整条链；返回 `null` 则继续到下一个
/// 中间件/处理函数。
pub const BeforeHandler = *const fn (*http.HttpRequest) anyerror!?http.HttpResponse;

/// 同步“after”钩子。在下游响应产生后运行，可以修改响应头部/状态。不得以
/// 与已计算的 Content-Length 冲突的方式改变响应体长度。
pub const AfterHandler = *const fn (*http.HttpRequest, *http.HttpResponse) anyerror!void;

/// 简单 before 风格中间件的向后兼容别名。
pub const Middleware = BeforeHandler;

const EntryKind = enum { onion, before, before_after, context };

const Entry = struct {
    kind: EntryKind,
    onion: ?MiddlewareHandler = null,
    before: ?BeforeHandler = null,
    after: ?AfterHandler = null,
    context_handler: ?ContextHandler = null,
    context: ?*anyopaque = null,
};

/// 为单个请求遍历中间件链。构造廉价（无堆分配）：它只持有指向流水线和
/// 路由器的指针，以及一个游标。
pub const Next = struct {
    pipeline: *const MiddlewarePipeline,
    router: *const router_mod.Router,
    index: usize = 0,

    /// 运行链中的下一个中间件，链耗尽时则分派到路由器。
    pub fn run(self: *Next, req: *http.HttpRequest) anyerror!http.HttpResponse {
        const entries = self.pipeline.entries.items;
        while (self.index < entries.len) {
            const entry = entries[self.index];
            self.index += 1;
            switch (entry.kind) {
                .onion => return entry.onion.?(req, self),
                .context => return entry.context_handler.?(entry.context.?, req, self),
                .before => {
                    if (try entry.before.?(req)) |response| return response;
                },
                .before_after => {
                    if (try entry.before.?(req)) |response| return response;
                    var response = try self.run(req);
                    if (entry.after) |after| try after(req, &response);
                    return response;
                },
            }
        }
        return self.router.dispatch(req);
    }
};

pub const MiddlewarePipeline = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator) MiddlewarePipeline {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MiddlewarePipeline) void {
        self.entries.deinit(self.allocator);
    }

    /// 注册一个简单的 before 风格中间件（返回响应即短路）。
    pub fn use(self: *MiddlewarePipeline, middleware: BeforeHandler) !void {
        try self.entries.append(self.allocator, .{ .kind = .before, .before = middleware });
    }

    /// 注册一个完整的洋葱模型中间件，由它控制是否调用 `next`。
    pub fn useOnion(self: *MiddlewarePipeline, middleware: MiddlewareHandler) !void {
        try self.entries.append(self.allocator, .{ .kind = .onion, .onion = middleware });
    }

    /// 注册一个携带上下文的洋葱中间件。不透明的 `context` 指针在每次请求时
    /// 回传给 `handler`，使有状态中间件无需堆分配闭包即可实现。`context` 归
    /// 调用方所有，且必须在整条流水线生命周期内保持存活。
    pub fn useOnionCtx(
        self: *MiddlewarePipeline,
        context: *anyopaque,
        handler: ContextHandler,
    ) !void {
        try self.entries.append(self.allocator, .{
            .kind = .context,
            .context_handler = handler,
            .context = context,
        });
    }

    /// 注册一对共享单个链帧的 before/after 钩子。
    pub fn useBeforeAfter(self: *MiddlewarePipeline, before: BeforeHandler, after: ?AfterHandler) !void {
        try self.entries.append(self.allocator, .{ .kind = .before_after, .before = before, .after = after });
    }

    pub fn size(self: *const MiddlewarePipeline) usize {
        return self.entries.items.len;
    }

    pub fn execute(self: *const MiddlewarePipeline, router: *const router_mod.Router, req: *http.HttpRequest) !http.HttpResponse {
        if (self.entries.items.len == 0) return router.dispatch(req);
        var next = Next{ .pipeline = self, .router = router };
        return next.run(req);
    }
};

test "empty pipeline dispatches directly to router" {
    var router = router_mod.Router.init(std.testing.allocator);
    defer router.deinit();
    const handler = struct {
        fn ok(_: *http.HttpRequest) !http.HttpResponse {
            return http.HttpResponse.text("dispatched");
        }
    }.ok;
    try router.get("/", handler);

    var pipeline = MiddlewarePipeline.init(std.testing.allocator);
    defer pipeline.deinit();

    var req: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/", .target = "/" };
    const response = try pipeline.execute(&router, &req);
    try std.testing.expectEqualStrings("dispatched", response.body);
}

test "before middleware can short-circuit" {
    var router = router_mod.Router.init(std.testing.allocator);
    defer router.deinit();
    const handler = struct {
        fn ok(_: *http.HttpRequest) !http.HttpResponse {
            return http.HttpResponse.text("handler");
        }
    }.ok;
    try router.get("/", handler);

    var pipeline = MiddlewarePipeline.init(std.testing.allocator);
    defer pipeline.deinit();
    const guard = struct {
        fn before(_: *http.HttpRequest) !?http.HttpResponse {
            return http.HttpResponse.text("blocked");
        }
    }.before;
    try pipeline.use(guard);

    var req: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/", .target = "/" };
    const response = try pipeline.execute(&router, &req);
    try std.testing.expectEqualStrings("blocked", response.body);
}

test "before middleware passes through when returning null" {
    var router = router_mod.Router.init(std.testing.allocator);
    defer router.deinit();
    const handler = struct {
        fn ok(_: *http.HttpRequest) !http.HttpResponse {
            return http.HttpResponse.text("handler");
        }
    }.ok;
    try router.get("/", handler);

    var pipeline = MiddlewarePipeline.init(std.testing.allocator);
    defer pipeline.deinit();
    const pass = struct {
        fn before(req: *http.HttpRequest) !?http.HttpResponse {
            try req.setAttribute("seen", "1");
            return null;
        }
    }.before;
    try pipeline.use(pass);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var req: http.HttpRequest = .{ .allocator = arena.allocator(), .method = .get, .path = "/", .target = "/" };
    const response = try pipeline.execute(&router, &req);
    try std.testing.expectEqualStrings("handler", response.body);
    try std.testing.expectEqualStrings("1", req.getAttribute("seen").?);
}

test "onion middleware wraps downstream response" {
    var router = router_mod.Router.init(std.testing.allocator);
    defer router.deinit();
    const handler = struct {
        fn ok(_: *http.HttpRequest) !http.HttpResponse {
            return http.HttpResponse.text("core");
        }
    }.ok;
    try router.get("/", handler);

    var pipeline = MiddlewarePipeline.init(std.testing.allocator);
    defer pipeline.deinit();
    const wrap = struct {
        fn handle(req: *http.HttpRequest, next: *Next) !http.HttpResponse {
            try req.setAttribute("before", "1");
            var response = try next.run(req);
            try response.setHeader("x-wrapped", "yes");
            return response;
        }
    }.handle;
    try pipeline.useOnion(wrap);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var req: http.HttpRequest = .{ .allocator = arena.allocator(), .method = .get, .path = "/", .target = "/" };
    const response = try pipeline.execute(&router, &req);
    try std.testing.expectEqualStrings("core", response.body);
    try std.testing.expectEqualStrings("yes", response.header("x-wrapped").?);
    try std.testing.expectEqualStrings("1", req.getAttribute("before").?);
}

test "onion middleware executes in registration order" {
    var router = router_mod.Router.init(std.testing.allocator);
    defer router.deinit();
    const handler = struct {
        fn ok(_: *http.HttpRequest) !http.HttpResponse {
            return http.HttpResponse.text("end");
        }
    }.ok;
    try router.get("/", handler);

    var pipeline = MiddlewarePipeline.init(std.testing.allocator);
    defer pipeline.deinit();
    const Order = struct {
        var trace: [8]u8 = undefined;
        var len: usize = 0;
        fn first(req: *http.HttpRequest, next: *Next) !http.HttpResponse {
            trace[len] = 'a';
            len += 1;
            const response = try next.run(req);
            trace[len] = 'A';
            len += 1;
            return response;
        }
        fn second(req: *http.HttpRequest, next: *Next) !http.HttpResponse {
            trace[len] = 'b';
            len += 1;
            const response = try next.run(req);
            trace[len] = 'B';
            len += 1;
            return response;
        }
    };
    Order.len = 0;
    try pipeline.useOnion(Order.first);
    try pipeline.useOnion(Order.second);

    var req: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/", .target = "/" };
    _ = try pipeline.execute(&router, &req);
    try std.testing.expectEqualStrings("abBA", Order.trace[0..Order.len]);
}

test "before/after pair runs after downstream" {
    var router = router_mod.Router.init(std.testing.allocator);
    defer router.deinit();
    const handler = struct {
        fn ok(_: *http.HttpRequest) !http.HttpResponse {
            return http.HttpResponse.text("body");
        }
    }.ok;
    try router.get("/", handler);

    var pipeline = MiddlewarePipeline.init(std.testing.allocator);
    defer pipeline.deinit();
    const hooks = struct {
        fn before(_: *http.HttpRequest) !?http.HttpResponse {
            return null;
        }
        fn after(_: *http.HttpRequest, response: *http.HttpResponse) !void {
            try response.setHeader("x-after", "done");
        }
    };
    try pipeline.useBeforeAfter(hooks.before, hooks.after);

    var req: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/", .target = "/" };
    const response = try pipeline.execute(&router, &req);
    try std.testing.expectEqualStrings("body", response.body);
    try std.testing.expectEqualStrings("done", response.header("x-after").?);
}

test "context onion middleware receives its context" {
    var router = router_mod.Router.init(std.testing.allocator);
    defer router.deinit();
    const handler = struct {
        fn ok(_: *http.HttpRequest) !http.HttpResponse {
            return http.HttpResponse.text("core");
        }
    }.ok;
    try router.get("/", handler);

    var pipeline = MiddlewarePipeline.init(std.testing.allocator);
    defer pipeline.deinit();

    const Ctx = struct {
        header_value: []const u8,
        fn handle(ptr: *anyopaque, req: *http.HttpRequest, next: *Next) !http.HttpResponse {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            var response = try next.run(req);
            try response.setHeader("x-ctx", self.header_value);
            return response;
        }
    };
    var ctx = Ctx{ .header_value = "from-context" };
    try pipeline.useOnionCtx(&ctx, Ctx.handle);

    var req: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/", .target = "/" };
    const response = try pipeline.execute(&router, &req);
    try std.testing.expectEqualStrings("core", response.body);
    try std.testing.expectEqualStrings("from-context", response.header("x-ctx").?);
}
