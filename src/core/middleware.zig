const std = @import("std");
const http = @import("http.zig");
const router_mod = @import("router.zig");

/// Onion-model middleware handler.
///
/// Each handler receives the request and a `*Next`. Calling `next.run(req)`
/// invokes the next middleware in the chain (or the final router dispatch when
/// the chain is exhausted). A handler may run logic before and after the
/// `next.run` call (the onion model), short-circuit by returning a response
/// without calling `next`, or transform the response returned by `next`.
pub const MiddlewareHandler = *const fn (*http.HttpRequest, *Next) anyerror!http.HttpResponse;

/// Onion-model middleware that carries an opaque context pointer, enabling
/// stateful middleware (CORS options, session managers, loggers) without heap
/// closures. The context is supplied at registration time via
/// `useOnionCtx`/`useOnionCtxValue` and passed back to the handler unchanged.
pub const ContextHandler = *const fn (*anyopaque, *http.HttpRequest, *Next) anyerror!http.HttpResponse;

/// A synchronous "before" hook. Returning a response short-circuits the chain;
/// returning `null` continues to the next middleware/handler.
pub const BeforeHandler = *const fn (*http.HttpRequest) anyerror!?http.HttpResponse;

/// A synchronous "after" hook. Runs after the downstream response is produced
/// and may mutate response headers/status. Must not change the body length in a
/// way that conflicts with an already-computed Content-Length.
pub const AfterHandler = *const fn (*http.HttpRequest, *http.HttpResponse) anyerror!void;

/// Backwards-compatible alias for the simple before-style middleware.
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

/// Walks the middleware chain for a single request. Cheap to construct (no heap
/// allocation): it holds pointers to the pipeline and router plus a cursor.
pub const Next = struct {
    pipeline: *const MiddlewarePipeline,
    router: *const router_mod.Router,
    index: usize = 0,

    /// Runs the next middleware in the chain, or dispatches to the router when
    /// the chain is exhausted.
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

    /// Registers a simple before-style middleware (short-circuit on response).
    pub fn use(self: *MiddlewarePipeline, middleware: BeforeHandler) !void {
        try self.entries.append(self.allocator, .{ .kind = .before, .before = middleware });
    }

    /// Registers a full onion-model middleware that controls calling `next`.
    pub fn useOnion(self: *MiddlewarePipeline, middleware: MiddlewareHandler) !void {
        try self.entries.append(self.allocator, .{ .kind = .onion, .onion = middleware });
    }

    /// Registers a context-carrying onion middleware. The opaque `context`
    /// pointer is passed back to `handler` on every request, enabling stateful
    /// middleware without heap-allocated closures. The caller owns `context`
    /// and must keep it alive for the lifetime of the pipeline.
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

    /// Registers a before/after pair sharing a single chain frame.
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
