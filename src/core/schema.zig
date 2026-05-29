//! 编译期 Zig 类型 -> OpenAPI 3.0.3 JSON Schema 反射。
//!
//! `writeSchema(w, T)` 会把 Zig 类型 `T` 的内联 JSON Schema 对象直接输出到
//! `std.json.Stringify` writer。不会使用 `$ref`/`components` 间接引用；每个
//! schema 都会在原处完全展开。映射如下：
//!
//!   - `bool`                 -> {"type":"boolean"}
//!   - 整数类型               -> {"type":"integer","format":"int32|int64"}
//!   - 浮点类型               -> {"type":"number","format":"float|double"}
//!   - `[]const u8`, `[N]u8`  -> {"type":"string"}            （字节字符串）
//!   - 其他切片/数组          -> {"type":"array","items":<schema>}
//!   - `?T`                   -> <T 的 schema> + "nullable":true
//!   - `enum`                 -> {"type":"string","enum":[...标签名]}
//!   - `struct`               -> {"type":"object","properties":{...},"required":[...]}
//!
//! 可选结构体字段会从 `required` 数组中省略。单项指针会被透明跟随。不支持的类型
//! 会在编译期失败，因此运行时永远不会输出不完整的 schema。

const std = @import("std");

/// 将 `T` 的 JSON Schema 输出到 `w`。对类型做编译期递归。
pub fn writeSchema(w: *std.json.Stringify, comptime T: type) !void {
    try writeSchemaInner(w, T, false);
}

fn writeSchemaInner(w: *std.json.Stringify, comptime T: type, comptime nullable: bool) anyerror!void {
    const info = @typeInfo(T);
    switch (info) {
        .bool => {
            try w.beginObject();
            try w.objectField("type");
            try w.write("boolean");
            if (nullable) try writeNullable(w);
            try w.endObject();
        },
        .int => |int_info| {
            try w.beginObject();
            try w.objectField("type");
            try w.write("integer");
            try w.objectField("format");
            try w.write(if (int_info.bits <= 32) "int32" else "int64");
            if (nullable) try writeNullable(w);
            try w.endObject();
        },
        .float => |float_info| {
            try w.beginObject();
            try w.objectField("type");
            try w.write("number");
            try w.objectField("format");
            try w.write(if (float_info.bits <= 32) "float" else "double");
            if (nullable) try writeNullable(w);
            try w.endObject();
        },
        .optional => |opt| {
            // 将 `?T` 折叠为 T 的 schema，并设置 nullable。
            try writeSchemaInner(w, opt.child, true);
        },
        .@"enum" => |enum_info| {
            try w.beginObject();
            try w.objectField("type");
            try w.write("string");
            try w.objectField("enum");
            try w.beginArray();
            inline for (enum_info.fields) |field| {
                try w.write(field.name);
            }
            try w.endArray();
            if (nullable) try writeNullable(w);
            try w.endObject();
        },
        .pointer => |ptr| {
            switch (ptr.size) {
                .slice => {
                    if (ptr.child == u8) {
                        // `[]const u8` / `[]u8` 视为字符串。
                        try w.beginObject();
                        try w.objectField("type");
                        try w.write("string");
                        if (nullable) try writeNullable(w);
                        try w.endObject();
                    } else {
                        try writeArray(w, ptr.child, nullable);
                    }
                },
                .one => {
                    // 透明跟随单项指针。
                    try writeSchemaInner(w, ptr.child, nullable);
                },
                else => @compileError("openapi schema: unsupported pointer size for " ++ @typeName(T)),
            }
        },
        .array => |arr| {
            if (arr.child == u8) {
                try w.beginObject();
                try w.objectField("type");
                try w.write("string");
                if (nullable) try writeNullable(w);
                try w.endObject();
            } else {
                try writeArray(w, arr.child, nullable);
            }
        },
        .@"struct" => |struct_info| {
            try w.beginObject();
            try w.objectField("type");
            try w.write("object");

            try w.objectField("properties");
            try w.beginObject();
            inline for (struct_info.fields) |field| {
                try w.objectField(field.name);
                try writeSchemaInner(w, field.type, false);
            }
            try w.endObject();

            // 非可选字段是必需字段。
            comptime var required_count = 0;
            inline for (struct_info.fields) |field| {
                if (@typeInfo(field.type) != .optional) required_count += 1;
            }
            if (required_count > 0) {
                try w.objectField("required");
                try w.beginArray();
                inline for (struct_info.fields) |field| {
                    if (@typeInfo(field.type) != .optional) {
                        try w.write(field.name);
                    }
                }
                try w.endArray();
            }

            if (nullable) try writeNullable(w);
            try w.endObject();
        },
        else => @compileError("openapi schema: unsupported type " ++ @typeName(T)),
    }
}

fn writeArray(w: *std.json.Stringify, comptime Child: type, comptime nullable: bool) !void {
    try w.beginObject();
    try w.objectField("type");
    try w.write("array");
    try w.objectField("items");
    try writeSchemaInner(w, Child, false);
    if (nullable) try writeNullable(w);
    try w.endObject();
}

fn writeNullable(w: *std.json.Stringify) !void {
    try w.objectField("nullable");
    try w.write(true);
}

// ----------------------------------------------------------------------------
// 测试
// ----------------------------------------------------------------------------

/// 将 `T` 的 schema 渲染为自有 JSON 字符串以供断言。
fn renderSchema(allocator: std.mem.Allocator, comptime T: type) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    var w = std.json.Stringify{ .writer = &out.writer };
    try writeSchema(&w, T);
    return out.toOwnedSlice();
}

fn parse(allocator: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json, .{});
}

test "scalar schemas" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    {
        const p = try parse(a, try renderSchema(a, bool));
        try std.testing.expectEqualStrings("boolean", p.value.object.get("type").?.string);
    }
    {
        const p = try parse(a, try renderSchema(a, i32));
        try std.testing.expectEqualStrings("integer", p.value.object.get("type").?.string);
        try std.testing.expectEqualStrings("int32", p.value.object.get("format").?.string);
    }
    {
        const p = try parse(a, try renderSchema(a, u64));
        try std.testing.expectEqualStrings("int64", p.value.object.get("format").?.string);
    }
    {
        const p = try parse(a, try renderSchema(a, f32));
        try std.testing.expectEqualStrings("number", p.value.object.get("type").?.string);
        try std.testing.expectEqualStrings("float", p.value.object.get("format").?.string);
    }
    {
        const p = try parse(a, try renderSchema(a, f64));
        try std.testing.expectEqualStrings("double", p.value.object.get("format").?.string);
    }
    {
        const p = try parse(a, try renderSchema(a, []const u8));
        try std.testing.expectEqualStrings("string", p.value.object.get("type").?.string);
    }
}

test "optional sets nullable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const p = try parse(a, try renderSchema(a, ?i32));
    try std.testing.expectEqualStrings("integer", p.value.object.get("type").?.string);
    try std.testing.expect(p.value.object.get("nullable").?.bool);
}

test "array of scalars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const p = try parse(a, try renderSchema(a, []const i32));
    try std.testing.expectEqualStrings("array", p.value.object.get("type").?.string);
    try std.testing.expectEqualStrings("integer", p.value.object.get("items").?.object.get("type").?.string);
}

test "enum becomes string enum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Color = enum { red, green, blue };
    const p = try parse(a, try renderSchema(a, Color));
    try std.testing.expectEqualStrings("string", p.value.object.get("type").?.string);
    const values = p.value.object.get("enum").?.array;
    try std.testing.expectEqual(@as(usize, 3), values.items.len);
    try std.testing.expectEqualStrings("red", values.items[0].string);
    try std.testing.expectEqualStrings("blue", values.items[2].string);
}

test "struct with required and optional fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const User = struct {
        id: u64,
        name: []const u8,
        nickname: ?[]const u8,
        active: bool,
    };

    const p = try parse(a, try renderSchema(a, User));
    const root = p.value.object;
    try std.testing.expectEqualStrings("object", root.get("type").?.string);

    const props = root.get("properties").?.object;
    try std.testing.expectEqualStrings("integer", props.get("id").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("string", props.get("name").?.object.get("type").?.string);
    try std.testing.expect(props.get("nickname").?.object.get("nullable").?.bool);
    try std.testing.expectEqualStrings("boolean", props.get("active").?.object.get("type").?.string);

    // required 排除可选的 `nickname`。
    const required = root.get("required").?.array;
    try std.testing.expectEqual(@as(usize, 3), required.items.len);
    for (required.items) |item| {
        try std.testing.expect(!std.mem.eql(u8, item.string, "nickname"));
    }
}

test "nested struct and array of structs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Tag = struct { label: []const u8 };
    const Post = struct {
        title: []const u8,
        tags: []const Tag,
        author: Tag,
    };

    const p = try parse(a, try renderSchema(a, Post));
    const props = p.value.object.get("properties").?.object;

    const tags = props.get("tags").?.object;
    try std.testing.expectEqualStrings("array", tags.get("type").?.string);
    const item = tags.get("items").?.object;
    try std.testing.expectEqualStrings("object", item.get("type").?.string);
    try std.testing.expectEqualStrings(
        "string",
        item.get("properties").?.object.get("label").?.object.get("type").?.string,
    );

    const author = props.get("author").?.object;
    try std.testing.expectEqualStrings("object", author.get("type").?.string);
}
