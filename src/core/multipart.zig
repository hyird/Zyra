//! multipart/form-data 解析器（RFC 7578）。
//!
//! 把 `multipart/form-data` 请求体解析为一组 `Part`，每个 `Part` 带有它的
//! 头部、表单字段名、可选的上传文件名、可选的内容类型，以及原始数据。
//! 另提供按文件/文本字段查找的便捷函数。所有返回的切片都引用传入的 `body`
//! 缓冲区（零拷贝）；只有 `Part` 数组和头部列表是从 `allocator` 分配的。

const std = @import("std");
const http = @import("http.zig");

pub const PartHeader = struct {
    name: []const u8,
    value: []const u8,
};

pub const Part = struct {
    headers: []const PartHeader = &.{},
    name: []const u8 = "",
    filename: []const u8 = "",
    content_type: []const u8 = "",
    data: []const u8 = "",

    pub fn isFile(self: Part) bool {
        return self.filename.len > 0;
    }

    pub fn header(self: Part, name: []const u8) ?[]const u8 {
        for (self.headers) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.value;
        }
        return null;
    }
};

pub const ParseError = error{
    NotMultipart,
    MissingBoundary,
    MalformedBody,
    OutOfMemory,
};

/// 用 `content_type` 中包含的 boundary 解析 `body`。
/// 返回从 `allocator` 分配的解析结果。返回的切片归调用方所有（用
/// `freeParts` 释放）；每个 part 内部的切片引用 `body`，不得比它存活更久。
pub fn parse(allocator: std.mem.Allocator, content_type: []const u8, body: []const u8) ParseError![]Part {
    const boundary = extractBoundary(content_type) orelse {
        if (std.ascii.indexOfIgnoreCase(content_type, "multipart/form-data") == null) {
            return error.NotMultipart;
        }
        return error.MissingBoundary;
    };

    var delimiter_buf: [74]u8 = undefined; // "--" + boundary(<=70) + 余量
    if (boundary.len + 2 > delimiter_buf.len) return error.MalformedBody;
    delimiter_buf[0] = '-';
    delimiter_buf[1] = '-';
    @memcpy(delimiter_buf[2 .. 2 + boundary.len], boundary);
    const delimiter = delimiter_buf[0 .. 2 + boundary.len];

    var parts: std.ArrayListUnmanaged(Part) = .empty;
    errdefer freePartsList(allocator, &parts);

    // 找到第一个 boundary。
    var cursor = std.mem.indexOf(u8, body, delimiter) orelse return error.MalformedBody;
    cursor += delimiter.len;

    while (true) {
        // 一个分隔符之后，期望要么是 "--"（结束符），要么是 CRLF。
        if (cursor + 2 <= body.len and body[cursor] == '-' and body[cursor + 1] == '-') {
            break; // 结束分隔符
        }
        // 跳过分隔符后面的 CRLF。
        if (cursor + 2 <= body.len and body[cursor] == '\r' and body[cursor + 1] == '\n') {
            cursor += 2;
        } else if (cursor < body.len and body[cursor] == '\n') {
            cursor += 1;
        } else {
            return error.MalformedBody;
        }

        // 头部块在第一个空行（CRLF CRLF）处结束。
        const header_end = std.mem.indexOf(u8, body[cursor..], "\r\n\r\n") orelse return error.MalformedBody;
        const header_block = body[cursor .. cursor + header_end];
        const data_start = cursor + header_end + 4;

        // 下一个分隔符（前面带 CRLF）标记本 part 数据的结束。
        const next_rel = std.mem.indexOf(u8, body[data_start..], delimiter) orelse return error.MalformedBody;
        var data_end = data_start + next_rel;
        // 去掉 boundary 分隔符前面的 CRLF。
        if (data_end >= 2 and body[data_end - 2] == '\r' and body[data_end - 1] == '\n') {
            data_end -= 2;
        } else if (data_end >= 1 and body[data_end - 1] == '\n') {
            data_end -= 1;
        }

        var part = Part{ .data = body[data_start..data_end] };
        try parsePartHeaders(allocator, header_block, &part);
        try parts.append(allocator, part);

        cursor = data_start + next_rel + delimiter.len;
        if (cursor > body.len) return error.MalformedBody;
    }

    return parts.toOwnedSlice(allocator);
}

/// 释放 `parse` 返回的 parts 切片。
pub fn freeParts(allocator: std.mem.Allocator, parts: []Part) void {
    for (parts) |part| allocator.free(part.headers);
    allocator.free(parts);
}

/// 缓存结果的包装，通过指针属性存放在请求上。
const CachedParts = struct {
    parts: []Part,
    /// 解析失败时设置，使重复调用返回相同的错误而不重新解析。
    /// `null` 表示成功。
    err: ?ParseError = null,
};

const cache_attr_key = "zyra.multipart.parts";

/// 把请求体解析为 `multipart/form-data`，并把结果缓存在请求上，使同一请求
/// 内的重复调用复用已解析的 parts 而不重新解析。分配使用 `req.allocator`
/// （请求 arena 生命周期）；返回的切片引用请求体，不得比请求存活更久。
/// 当请求不是 multipart 时返回 `error.NotMultipart`。
pub fn cachedParse(req: *http.HttpRequest) ParseError![]Part {
    if (req.getAttributePtr(cache_attr_key)) |ptr| {
        const cached: *CachedParts = @ptrCast(@alignCast(ptr));
        if (cached.err) |e| return e;
        return cached.parts;
    }

    const allocator = req.allocator;
    const content_type = req.contentType() orelse return error.NotMultipart;

    const cached = allocator.create(CachedParts) catch return error.OutOfMemory;
    const result = parse(allocator, content_type, req.body());
    cached.* = if (result) |parts|
        .{ .parts = parts }
    else |e|
        .{ .parts = &.{}, .err = e };

    // 尽力缓存；即使存属性失败，仍返回结果。
    req.setAttributePtr(cache_attr_key, cached) catch {};

    if (cached.err) |e| return e;
    return cached.parts;
}

fn freePartsList(allocator: std.mem.Allocator, parts: *std.ArrayListUnmanaged(Part)) void {
    for (parts.items) |part| allocator.free(part.headers);
    parts.deinit(allocator);
}

/// 返回具有给定表单字段名的第一个文件 part。
pub fn getFile(parts: []const Part, field_name: []const u8) ?Part {
    for (parts) |part| {
        if (part.isFile() and std.mem.eql(u8, part.name, field_name)) return part;
    }
    return null;
}

/// 返回具有给定表单字段名的第一个非文件 part 的值。
pub fn getField(parts: []const Part, field_name: []const u8) ?[]const u8 {
    for (parts) |part| {
        if (!part.isFile() and std.mem.eql(u8, part.name, field_name)) return part.data;
    }
    return null;
}

/// 从 `multipart/form-data` 内容类型中提取 boundary 标记。
pub fn extractBoundary(content_type: []const u8) ?[]const u8 {
    const idx = std.ascii.indexOfIgnoreCase(content_type, "boundary=") orelse return null;
    var value = content_type[idx + "boundary=".len ..];
    // 在下一个参数分隔符处停止。
    if (std.mem.indexOfScalar(u8, value, ';')) |semi| value = value[0..semi];
    value = std.mem.trim(u8, value, " \t");
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        value = value[1 .. value.len - 1];
    }
    if (value.len == 0) return null;
    return value;
}

fn parsePartHeaders(allocator: std.mem.Allocator, header_block: []const u8, part: *Part) ParseError!void {
    var headers: std.ArrayListUnmanaged(PartHeader) = .empty;
    errdefer headers.deinit(allocator);

    var lines = std.mem.splitSequence(u8, header_block, "\r\n");
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t");
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        try headers.append(allocator, .{ .name = name, .value = value });

        if (std.ascii.eqlIgnoreCase(name, "content-disposition")) {
            parseDispositionParams(value, part);
        } else if (std.ascii.eqlIgnoreCase(name, "content-type")) {
            part.content_type = value;
        }
    }

    part.headers = try headers.toOwnedSlice(allocator);
}

fn parseDispositionParams(disposition: []const u8, part: *Part) void {
    if (extractParam(disposition, "name")) |name| part.name = name;
    if (extractParam(disposition, "filename")) |filename| part.filename = filename;
}

fn extractParam(input: []const u8, key: []const u8) ?[]const u8 {
    var search = input;
    while (std.ascii.indexOfIgnoreCase(search, key)) |rel| {
        const after = search[rel + key.len ..];
        const trimmed = std.mem.trimStart(u8, after, " \t");
        if (trimmed.len > 0 and trimmed[0] == '=') {
            var value = std.mem.trimStart(u8, trimmed[1..], " \t");
            if (value.len > 0 and value[0] == '"') {
                value = value[1..];
                const end = std.mem.indexOfScalar(u8, value, '"') orelse value.len;
                return value[0..end];
            }
            const end = std.mem.indexOfAny(u8, value, "; \t") orelse value.len;
            return value[0..end];
        }
        search = search[rel + key.len ..];
    }
    return null;
}

const test_body =
    "--X\r\n" ++
    "Content-Disposition: form-data; name=\"username\"\r\n" ++
    "\r\n" ++
    "zig-dev\r\n" ++
    "--X\r\n" ++
    "Content-Disposition: form-data; name=\"avatar\"; filename=\"a.png\"\r\n" ++
    "Content-Type: image/png\r\n" ++
    "\r\n" ++
    "BINARYDATA\r\n" ++
    "--X--\r\n";

test "parse extracts text and file parts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parts = try parse(arena.allocator(), "multipart/form-data; boundary=X", test_body);
    try std.testing.expectEqual(@as(usize, 2), parts.len);

    try std.testing.expectEqualStrings("username", parts[0].name);
    try std.testing.expect(!parts[0].isFile());
    try std.testing.expectEqualStrings("zig-dev", parts[0].data);

    try std.testing.expectEqualStrings("avatar", parts[1].name);
    try std.testing.expect(parts[1].isFile());
    try std.testing.expectEqualStrings("a.png", parts[1].filename);
    try std.testing.expectEqualStrings("image/png", parts[1].content_type);
    try std.testing.expectEqualStrings("BINARYDATA", parts[1].data);
}

test "getField and getFile look up by name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parts = try parse(arena.allocator(), "multipart/form-data; boundary=X", test_body);
    try std.testing.expectEqualStrings("zig-dev", getField(parts, "username").?);
    try std.testing.expect(getField(parts, "avatar") == null);

    const file = getFile(parts, "avatar").?;
    try std.testing.expectEqualStrings("a.png", file.filename);
    try std.testing.expect(getFile(parts, "username") == null);
}

test "extractBoundary handles quotes and trailing params" {
    try std.testing.expectEqualStrings("abc", extractBoundary("multipart/form-data; boundary=abc").?);
    try std.testing.expectEqualStrings("a b", extractBoundary("multipart/form-data; boundary=\"a b\"; charset=utf-8").?);
    try std.testing.expect(extractBoundary("application/json") == null);
}

test "parse rejects non-multipart and missing boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.NotMultipart, parse(arena.allocator(), "application/json", "{}"));
    try std.testing.expectError(error.MissingBoundary, parse(arena.allocator(), "multipart/form-data", test_body));
}

test "parse via request content type and body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = http.HttpRequest.initParsed(arena.allocator(), "POST", "/upload", "multipart/form-data; boundary=X", null, true);
    defer req.deinit();
    req.body_bytes = test_body;

    const parts = try parse(req.allocator, req.contentType().?, req.body());
    try std.testing.expectEqual(@as(usize, 2), parts.len);
    try std.testing.expectEqualStrings("zig-dev", getField(parts, "username").?);
}

test "cachedParse parses once and reuses the cached result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = http.HttpRequest.initParsed(arena.allocator(), "POST", "/upload", "multipart/form-data; boundary=X", null, true);
    defer req.deinit();
    req.body_bytes = test_body;

    const first = try cachedParse(&req);
    const second = try cachedParse(&req);
    try std.testing.expectEqual(@as(usize, 2), first.len);
    // 同一个底层切片指针 -> 第二次调用复用了缓存。
    try std.testing.expectEqual(first.ptr, second.ptr);
    try std.testing.expectEqualStrings("zig-dev", getField(second, "username").?);
}

test "cachedParse returns NotMultipart for non-multipart requests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = http.HttpRequest.initParsed(arena.allocator(), "POST", "/upload", "application/json", null, true);
    defer req.deinit();
    req.body_bytes = "{}";

    try std.testing.expectError(error.NotMultipart, cachedParse(&req));
    // 缓存错误路径：第二次调用仍报告相同的错误。
    try std.testing.expectError(error.NotMultipart, cachedParse(&req));
}
