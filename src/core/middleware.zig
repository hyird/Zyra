const std = @import("std");
const http = @import("http.zig");
const router_mod = @import("router.zig");

pub const Middleware = *const fn (*http.HttpRequest) anyerror!?http.HttpResponse;

pub const MiddlewarePipeline = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Middleware) = .empty,

    pub fn init(allocator: std.mem.Allocator) MiddlewarePipeline {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MiddlewarePipeline) void {
        self.entries.deinit(self.allocator);
    }

    pub fn use(self: *MiddlewarePipeline, middleware: Middleware) !void {
        try self.entries.append(self.allocator, middleware);
    }

    pub fn execute(self: *const MiddlewarePipeline, router: *const router_mod.Router, req: *http.HttpRequest) !http.HttpResponse {
        if (self.entries.items.len == 0) return router.dispatch(req);

        for (self.entries.items) |middleware| {
            if (try middleware(req)) |response| return response;
        }
        return router.dispatch(req);
    }
};
