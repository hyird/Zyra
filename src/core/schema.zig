//! Compile-time Zig type -> OpenAPI 3.0.3 JSON Schema reflection.
//!
//! `writeSchema(w, T)` emits an inline JSON Schema object for the Zig type `T`
//! directly into a `std.json.Stringify` writer. No `$ref`/`components` indirection
//! is used; every schema is fully expanded in place. The mapping is:
//!
//!   - `bool`                 -> {"type":"boolean"}
//!   - integer types          -> {"type":"integer","format":"int32|int64"}
//!   - float types            -> {"type":"number","format":"float|double"}
//!   - `[]const u8`, `[N]u8`  -> {"type":"string"}            (byte strings)
//!   - other slices/arrays    -> {"type":"array","items":<schema>}
//!   - `?T`                   -> <schema of T> + "nullable":true
//!   - `enum`                 -> {"type":"string","enum":[...tag names]}
//!   - `struct`               -> {"type":"object","properties":{...},"required":[...]}
//!
//! Optional struct fields are omitted from the `required` array. Pointers to a
//! single item are transparently followed. Unsupported types fail at compile
//! time so an incomplete schema can never be emitted at runtime.

const std = @import("std");

/// Emits the JSON Schema for `T` into `w`. Comptime-recursive over the type.
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
            // Collapse `?T` into T's schema with nullable set.
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
                        // `[]const u8` / `[]u8` are treated as strings.
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
                    // Transparently follow single-item pointers.
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

            // Non-optional fields are required.
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
// Tests
// ----------------------------------------------------------------------------

/// Renders `T`'s schema to an owned JSON string for assertions.
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

    // required excludes the optional `nickname`.
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
