const std = @import("std");
const zyra = @import("zyra");

fn index(_: *zyra.HttpRequest) !zyra.HttpResponse {
    return zyra.HttpResponse.text("Hello from Zyra\n");
}

fn user(req: *zyra.HttpRequest) !zyra.HttpResponse {
    const id = req.param("id") orelse "unknown";
    return zyra.HttpResponse.text(id);
}

fn trace(req: *zyra.HttpRequest) !?zyra.HttpResponse {
    std.log.info("{s} {s}", .{ @tagName(req.method), req.path });
    return null;
}

pub fn main() !void {
    var server = zyra.HttpServer.init(std.heap.smp_allocator, .{ .port = 3000, .io_threads = 2 });
    defer server.deinit();

    try server.use(trace);
    try server.router().get("/", index);
    try server.router().get("/users/{id}", user);

    try server.start();
}
