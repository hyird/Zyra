//! OpenAPI 3.0.3 document generation.
//!
//! `OpenApiDocument` collects registered operations (HTTP method, path,
//! optional summary) and emits a valid OpenAPI 3.0.3 JSON document. Path
//! parameters written as `{name}` are surfaced as required path parameters.
//! The generated JSON is produced with `std.json` and is owned by the caller.

const std = @import("std");
const http = @import("http.zig");
const Router = @import("router.zig").Router;
const schema = @import("schema.zig");

pub const Operation = struct {
    method: http.HttpMethod,
    path: []const u8,
    summary: []const u8 = "",
    /// Pre-rendered JSON Schema for the request body (owned by the document),
    /// or null when the operation takes no JSON body.
    request_schema: ?[]const u8 = null,
    /// Pre-rendered JSON Schema for the 200 response body (owned by the
    /// document), or null when the response has no documented schema.
    response_schema: ?[]const u8 = null,
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
        for (self.operations.items) |op| {
            if (op.request_schema) |s| self.allocator.free(s);
            if (op.response_schema) |s| self.allocator.free(s);
        }
        self.operations.deinit(self.allocator);
    }

    /// Registers an operation. `summary` may be empty.
    pub fn addOperation(self: *OpenApiDocument, method: http.HttpMethod, path: []const u8, summary: []const u8) !void {
        try self.operations.append(self.allocator, .{ .method = method, .path = path, .summary = summary });
    }

    /// Options for `addJsonOperation`. `Request`/`Response` are Zig types whose
    /// JSON Schema is reflected at compile time; leave them as the default
    /// `null` (i.e. omit) when the operation has no JSON request/response body.
    pub const JsonOperationOptions = struct {
        summary: []const u8 = "",
    };

    /// Registers an operation whose request and/or response bodies are described
    /// by reflecting the given Zig types into inline JSON Schemas. Pass the
    /// types via the `Request`/`Response` comptime parameters; use `void` to
    /// indicate "no body". The rendered schemas are owned by the document.
    pub fn addJsonOperation(
        self: *OpenApiDocument,
        comptime Request: type,
        comptime Response: type,
        method: http.HttpMethod,
        path: []const u8,
        options: JsonOperationOptions,
    ) !void {
        const request_schema: ?[]const u8 = if (Request == void)
            null
        else
            try renderSchema(self.allocator, Request);
        errdefer if (request_schema) |s| self.allocator.free(s);

        const response_schema: ?[]const u8 = if (Response == void)
            null
        else
            try renderSchema(self.allocator, Response);
        errdefer if (response_schema) |s| self.allocator.free(s);

        try self.operations.append(self.allocator, .{
            .method = method,
            .path = path,
            .summary = options.summary,
            .request_schema = request_schema,
            .response_schema = response_schema,
        });
    }

    /// Collects every HTTP route registered on `router` as an operation
    /// (without summaries). Path strings are borrowed from the router and must
    /// outlive document generation. Routes already present (matched by method
    /// and path) are skipped, so schemas added beforehand (e.g. via
    /// `addJsonOperation`) are preserved.
    pub fn collectFromRouter(self: *OpenApiDocument, router: *const Router) !void {
        try router.forEachRoute(self, collectCallback);
    }

    /// Returns true if an operation with the given method and path is already
    /// registered.
    pub fn hasOperation(self: *const OpenApiDocument, method: http.HttpMethod, path: []const u8) bool {
        for (self.operations.items) |op| {
            if (op.method == method and std.mem.eql(u8, op.path, path)) return true;
        }
        return false;
    }

    fn collectCallback(self: *OpenApiDocument, method: http.HttpMethod, path: []const u8) anyerror!void {
        if (self.hasOperation(method, path)) return;
        try self.addOperation(method, path, "");
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

        // Request body schema, when the operation documents one.
        if (op.request_schema) |req_schema| {
            try w.objectField("requestBody");
            try w.beginObject();
            try w.objectField("required");
            try w.write(true);
            try w.objectField("content");
            try w.beginObject();
            try w.objectField("application/json");
            try w.beginObject();
            try w.objectField("schema");
            try writeRawJson(w, req_schema);
            try w.endObject();
            try w.endObject();
            try w.endObject();
        }

        try w.objectField("responses");
        try w.beginObject();
        try w.objectField("200");
        try w.beginObject();
        try w.objectField("description");
        try w.write("Successful response");
        if (op.response_schema) |resp_schema| {
            try w.objectField("content");
            try w.beginObject();
            try w.objectField("application/json");
            try w.beginObject();
            try w.objectField("schema");
            try writeRawJson(w, resp_schema);
            try w.endObject();
            try w.endObject();
        }
        try w.endObject();
        try w.endObject();

        try w.endObject();
    }
};

fn renderSchema(allocator: std.mem.Allocator, comptime T: type) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    var w = std.json.Stringify{ .writer = &out.writer };
    try schema.writeSchema(&w, T);
    return out.toOwnedSlice();
}

/// Emits a pre-rendered JSON value (e.g. a reflected schema) as a raw value at
/// the current position in the stringifier.
fn writeRawJson(w: *std.json.Stringify, raw: []const u8) !void {
    try w.beginWriteRaw();
    try w.writer.writeAll(raw);
    w.endWriteRaw();
}

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

test "collectFromRouter gathers registered routes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const handler = struct {
        fn h(_: *http.HttpRequest) anyerror!http.HttpResponse {
            return http.HttpResponse.text("ok");
        }
    }.h;

    var router = Router.init(alloc);
    defer router.deinit();
    try router.get("/users", handler);
    try router.post("/users", handler);
    try router.get("/users/{id}", handler);

    var doc = OpenApiDocument.init(alloc, .{ .title = "From Router" });
    defer doc.deinit();
    try doc.collectFromRouter(&router);
    try std.testing.expectEqual(@as(usize, 3), doc.operations.items.len);

    const json = try doc.generate();
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();

    const paths = parsed.value.object.get("paths").?.object;
    const users = paths.get("/users").?.object;
    try std.testing.expect(users.get("get") != null);
    try std.testing.expect(users.get("post") != null);

    const by_id = paths.get("/users/{id}").?.object.get("get").?.object;
    const params = by_id.get("parameters").?.array;
    try std.testing.expectEqualStrings("id", params.items[0].object.get("name").?.string);
}

test "addJsonOperation reflects request and response schemas" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const CreateUser = struct {
        name: []const u8,
        age: ?u32,
    };
    const User = struct {
        id: u64,
        name: []const u8,
    };

    var doc = OpenApiDocument.init(a, .{ .title = "Schema API" });
    defer doc.deinit();
    try doc.addJsonOperation(CreateUser, User, .post, "/users", .{ .summary = "Create user" });
    // Response-only operation (no request body).
    try doc.addJsonOperation(void, User, .get, "/users/{id}", .{});

    const json = try doc.generate();
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();

    const paths = parsed.value.object.get("paths").?.object;

    // POST /users: requestBody schema reflected from CreateUser.
    const post = paths.get("/users").?.object.get("post").?.object;
    try std.testing.expectEqualStrings("Create user", post.get("summary").?.string);
    const req_schema = post.get("requestBody").?.object
        .get("content").?.object
        .get("application/json").?.object
        .get("schema").?.object;
    try std.testing.expectEqualStrings("object", req_schema.get("type").?.string);
    const req_props = req_schema.get("properties").?.object;
    try std.testing.expectEqualStrings("string", req_props.get("name").?.object.get("type").?.string);
    try std.testing.expect(req_props.get("age").?.object.get("nullable").?.bool);
    // Only `name` is required (age is optional).
    const req_required = req_schema.get("required").?.array;
    try std.testing.expectEqual(@as(usize, 1), req_required.items.len);
    try std.testing.expectEqualStrings("name", req_required.items[0].string);

    // POST /users: 200 response schema reflected from User.
    const post_resp = post.get("responses").?.object.get("200").?.object;
    const resp_schema = post_resp.get("content").?.object
        .get("application/json").?.object
        .get("schema").?.object;
    const resp_props = resp_schema.get("properties").?.object;
    try std.testing.expectEqualStrings("integer", resp_props.get("id").?.object.get("type").?.string);

    // GET /users/{id}: no requestBody, but a response schema.
    const get = paths.get("/users/{id}").?.object.get("get").?.object;
    try std.testing.expect(get.get("requestBody") == null);
    try std.testing.expect(get.get("responses").?.object
        .get("200").?.object.get("content") != null);
}
