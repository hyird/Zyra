//! OpenAPI 3.0.3 document generation.
//!
//! `OpenApiDocument` collects registered operations (HTTP method, path,
//! optional summary) and emits a valid OpenAPI 3.0.3 JSON document. Path
//! parameters written as `{name}` are surfaced as required path parameters.
//! The generated JSON is produced with `std.json` and is owned by the caller.

const std = @import("std");
const http = @import("http.zig");

pub const Operation = struct {
    method: http.HttpMethod,
    path: []const u8,
    summary: []const u8 = "",
};

pub const Server = struct {
    url: []const u8,
    description: []const u8 = "",
};

pub const Config = struct {
    title: []const u8 = "Zyra API",
    version: []const u8 = "1.0.0",
    description: []const u8 = "",
    servers: []const Server = &.{},
};

pub const OpenApiDocument = struct {
    allocator: std.mem.Allocator,
    config: Config,
    operations: std.ArrayListUnmanaged(Operation) = .empty,

    pub fn init(allocator: std.mem.Allocator, config: Config) OpenApiDocument {
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *OpenApiDocument) void {
        self.operations.deinit(self.allocator);
    }

    /// Registers an operation. `summary` may be empty.
    pub fn addOperation(self: *OpenApiDocument, method: http.HttpMethod, path: []const u8, summary: []const u8) !void {
        try self.operations.append(self.allocator, .{ .method = method, .path = path, .summary = summary });
    }

    /// Generates the OpenAPI JSON document. The returned slice is owned by the
    /// caller and allocated from the document's allocator.
    pub fn generate(self: *const OpenApiDocument) ![]const u8 {
        var out = std.Io.Writer.Allocating.init(self.allocator);
        errdefer out.deinit();
        var w = std.json.Stringify{ .writer = &out.writer };

        try w.beginObject();

        try w.objectField("openapi");
        try w.write("3.0.3");

        try w.objectField("info");
        try w.beginObject();
        try w.objectField("title");
        try w.write(self.config.title);
        try w.objectField("version");
        try w.write(self.config.version);
        if (self.config.description.len > 0) {
            try w.objectField("description");
            try w.write(self.config.description);
        }
        try w.endObject();

        if (self.config.servers.len > 0) {
            try w.objectField("servers");
            try w.beginArray();
            for (self.config.servers) |server| {
                try w.beginObject();
                try w.objectField("url");
                try w.write(server.url);
                if (server.description.len > 0) {
                    try w.objectField("description");
                    try w.write(server.description);
                }
                try w.endObject();
            }
            try w.endArray();
        }

        try w.objectField("paths");
        try self.writePaths(&w);

        try w.endObject();

        return out.toOwnedSlice();
    }

    fn writePaths(self: *const OpenApiDocument, w: *std.json.Stringify) !void {
        try w.beginObject();

        // Group operations by path, preserving first-seen order.
        var seen_paths: std.ArrayListUnmanaged([]const u8) = .empty;
        defer seen_paths.deinit(self.allocator);

        for (self.operations.items) |op| {
            if (containsPath(seen_paths.items, op.path)) continue;
            try seen_paths.append(self.allocator, op.path);

            try w.objectField(op.path);
            try w.beginObject();
            for (self.operations.items) |inner| {
                if (!std.mem.eql(u8, inner.path, op.path)) continue;
                const verb = methodToLower(inner.method) orelse continue;
                try w.objectField(verb);
                try self.writeOperation(w, inner);
            }
            try w.endObject();
        }

        try w.endObject();
    }

    fn writeOperation(self: *const OpenApiDocument, w: *std.json.Stringify, op: Operation) !void {
        _ = self;
        try w.beginObject();
        if (op.summary.len > 0) {
            try w.objectField("summary");
            try w.write(op.summary);
        }

        // Path parameters from {name} segments.
        var has_params = false;
        var it = pathParamIterator(op.path);
        while (it.next()) |_| {
            has_params = true;
            break;
        }
        if (has_params) {
            try w.objectField("parameters");
            try w.beginArray();
            var pit = pathParamIterator(op.path);
            while (pit.next()) |name| {
                try w.beginObject();
                try w.objectField("name");
                try w.write(name);
                try w.objectField("in");
                try w.write("path");
                try w.objectField("required");
                try w.write(true);
                try w.objectField("schema");
                try w.beginObject();
                try w.objectField("type");
                try w.write("string");
                try w.endObject();
                try w.endObject();
            }
            try w.endArray();
        }

        try w.objectField("responses");
        try w.beginObject();
        try w.objectField("200");
        try w.beginObject();
        try w.objectField("description");
        try w.write("Successful response");
        try w.endObject();
        try w.endObject();

        try w.endObject();
    }
};

fn containsPath(paths: []const []const u8, path: []const u8) bool {
    for (paths) |p| {
        if (std.mem.eql(u8, p, path)) return true;
    }
    return false;
}

fn methodToLower(method: http.HttpMethod) ?[]const u8 {
    return switch (method) {
        .get => "get",
        .post => "post",
        .put => "put",
        .patch => "patch",
        .delete => "delete",
        .head => "head",
        .options => "options",
        else => null,
    };
}

const PathParamIterator = struct {
    path: []const u8,
    index: usize = 0,

    fn next(self: *PathParamIterator) ?[]const u8 {
        while (self.index < self.path.len) {
            const open = std.mem.indexOfScalarPos(u8, self.path, self.index, '{') orelse return null;
            const close = std.mem.indexOfScalarPos(u8, self.path, open, '}') orelse return null;
            self.index = close + 1;
            if (close > open + 1) return self.path[open + 1 .. close];
        }
        return null;
    }
};

fn pathParamIterator(path: []const u8) PathParamIterator {
    return .{ .path = path };
}

test "methodToLower covers verbs" {
    try std.testing.expectEqualStrings("get", methodToLower(.get).?);
    try std.testing.expectEqualStrings("delete", methodToLower(.delete).?);
    try std.testing.expect(methodToLower(.unknown) == null);
}

test "pathParamIterator extracts params" {
    var it = pathParamIterator("/users/{id}/posts/{postId}");
    try std.testing.expectEqualStrings("id", it.next().?);
    try std.testing.expectEqualStrings("postId", it.next().?);
    try std.testing.expect(it.next() == null);
}

test "generate emits valid openapi document" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var doc = OpenApiDocument.init(arena.allocator(), .{ .title = "Test API", .version = "2.0.0" });
    defer doc.deinit();
    try doc.addOperation(.get, "/users/{id}", "Get a user");
    try doc.addOperation(.post, "/users", "Create a user");

    const json = try doc.generate();

    // Must be parseable and contain expected fields.
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("3.0.3", root.get("openapi").?.string);
    try std.testing.expectEqualStrings("Test API", root.get("info").?.object.get("title").?.string);

    const paths = root.get("paths").?.object;
    const user_path = paths.get("/users/{id}").?.object;
    const get_op = user_path.get("get").?.object;
    try std.testing.expectEqualStrings("Get a user", get_op.get("summary").?.string);

    const params = get_op.get("parameters").?.array;
    try std.testing.expectEqual(@as(usize, 1), params.items.len);
    try std.testing.expectEqualStrings("id", params.items[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("path", params.items[0].object.get("in").?.string);
}

test "generate groups multiple methods under one path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var doc = OpenApiDocument.init(arena.allocator(), .{});
    defer doc.deinit();
    try doc.addOperation(.get, "/items", "List");
    try doc.addOperation(.post, "/items", "Create");

    const json = try doc.generate();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), json, .{});
    defer parsed.deinit();

    const items = parsed.value.object.get("paths").?.object.get("/items").?.object;
    try std.testing.expect(items.get("get") != null);
    try std.testing.expect(items.get("post") != null);
}
