//! multipart/form-data parser (RFC 7578).
//!
//! Parses a `multipart/form-data` request body into a list of `Part` values,
//! each carrying its headers, form field name, optional upload filename,
//! optional content type, and raw data. Convenience lookups for file and text
//! fields are provided. All returned slices reference the supplied `body`
//! buffer (zero-copy); only the `Part` array and the headers list are allocated
//! from `allocator`.

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

/// Parses `body` using the boundary contained in `content_type`.
/// Returns the parsed parts allocated from `allocator`. The caller owns the
/// returned slice (free with `freeParts`); slices inside each part reference
/// `body` and must not outlive it.
pub fn parse(allocator: std.mem.Allocator, content_type: []const u8, body: []const u8) ParseError![]Part {
    const boundary = extractBoundary(content_type) orelse {
        if (std.ascii.indexOfIgnoreCase(content_type, "multipart/form-data") == null) {
            return error.NotMultipart;
        }
        return error.MissingBoundary;
    };

    var delimiter_buf: [74]u8 = undefined; // "--" + boundary(<=70) + slack
    if (boundary.len + 2 > delimiter_buf.len) return error.MalformedBody;
    delimiter_buf[0] = '-';
    delimiter_buf[1] = '-';
    @memcpy(delimiter_buf[2 .. 2 + boundary.len], boundary);
    const delimiter = delimiter_buf[0 .. 2 + boundary.len];

    var parts: std.ArrayListUnmanaged(Part) = .empty;
    errdefer freePartsList(allocator, &parts);

    // Find the first boundary.
    var cursor = std.mem.indexOf(u8, body, delimiter) orelse return error.MalformedBody;
    cursor += delimiter.len;

    while (true) {
        // After a delimiter we expect either "--" (terminator) or CRLF.
        if (cursor + 2 <= body.len and body[cursor] == '-' and body[cursor + 1] == '-') {
            break; // closing delimiter
        }
        // Skip the trailing CRLF after the delimiter.
        if (cursor + 2 <= body.len and body[cursor] == '\r' and body[cursor + 1] == '\n') {
            cursor += 2;
        } else if (cursor < body.len and body[cursor] == '\n') {
            cursor += 1;
        } else {
            return error.MalformedBody;
        }

        // Header block ends at the first blank line (CRLF CRLF).
        const header_end = std.mem.indexOf(u8, body[cursor..], "\r\n\r\n") orelse return error.MalformedBody;
        const header_block = body[cursor .. cursor + header_end];
        const data_start = cursor + header_end + 4;

        // The next delimiter (preceded by CRLF) terminates this part's data.
        const next_rel = std.mem.indexOf(u8, body[data_start..], delimiter) orelse return error.MalformedBody;
        var data_end = data_start + next_rel;
        // Strip the CRLF that precedes the boundary delimiter.
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

/// Frees a parts slice returned by `parse`.
pub fn freeParts(allocator: std.mem.Allocator, parts: []Part) void {
    for (parts) |part| allocator.free(part.headers);
    allocator.free(parts);
}

fn freePartsList(allocator: std.mem.Allocator, parts: *std.ArrayListUnmanaged(Part)) void {
    for (parts.items) |part| allocator.free(part.headers);
    parts.deinit(allocator);
}

/// Returns the first file part with the given form field name.
pub fn getFile(parts: []const Part, field_name: []const u8) ?Part {
    for (parts) |part| {
        if (part.isFile() and std.mem.eql(u8, part.name, field_name)) return part;
    }
    return null;
}

/// Returns the value of the first non-file part with the given form field name.
pub fn getField(parts: []const Part, field_name: []const u8) ?[]const u8 {
    for (parts) |part| {
        if (!part.isFile() and std.mem.eql(u8, part.name, field_name)) return part.data;
    }
    return null;
}

/// Extracts the boundary token from a `multipart/form-data` content type.
pub fn extractBoundary(content_type: []const u8) ?[]const u8 {
    const idx = std.ascii.indexOfIgnoreCase(content_type, "boundary=") orelse return null;
    var value = content_type[idx + "boundary=".len ..];
    // Stop at the next parameter separator.
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
