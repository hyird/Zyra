const std = @import("std");
const http = @import("http.zig");

const c = @cImport({
    @cInclude("picohttpparser.h");
});

pub const ParseError = error{
    EndOfStream,
    HeaderTooLarge,
    MalformedRequest,
};

pub const ParsedRequest = struct {
    method: []const u8,
    target: []const u8,
    minor_version: i32,
    content_type: ?[]const u8 = null,
    content_length: ?u64 = null,
    keep_alive: bool = true,
    header_bytes: usize,
};

pub const SessionBuffer = struct {
    buf: []u8,
    used: usize = 0,

    pub fn readHead(self: *SessionBuffer, reader: *std.Io.Reader, max_header_size: usize) !ParsedRequest {
        var previous_len: usize = 0;

        while (true) {
            if (self.used > previous_len) {
                if (try parse(self.buf[0..self.used], previous_len)) |parsed| return parsed;
                previous_len = self.used;
            }

            if (self.used >= self.buf.len) return error.HeaderTooLarge;
            if (self.used >= max_header_size) return error.HeaderTooLarge;

            var data: [1][]u8 = .{self.buf[self.used..]};
            const n = try reader.readVec(&data);
            if (n == 0) return error.EndOfStream;
            self.used += n;
            if (self.used > max_header_size) return error.HeaderTooLarge;
        }
    }

    pub fn consume(self: *SessionBuffer, n: usize) void {
        const remaining = self.used - n;
        if (remaining > 0) std.mem.copyForwards(u8, self.buf[0..remaining], self.buf[n..self.used]);
        self.used = remaining;
    }
};

fn parse(bytes: []u8, previous_len: usize) !?ParsedRequest {
    var method_ptr: [*c]const u8 = null;
    var method_len: usize = 0;
    var path_ptr: [*c]const u8 = null;
    var path_len: usize = 0;
    var minor_version: c_int = 0;
    var headers: [64]c.phr_header = undefined;
    var num_headers: usize = headers.len;

    const rc = c.phr_parse_request(
        bytes.ptr,
        bytes.len,
        &method_ptr,
        &method_len,
        &path_ptr,
        &path_len,
        &minor_version,
        &headers,
        &num_headers,
        previous_len,
    );

    if (rc == -2) return null;
    if (rc < 0) return error.MalformedRequest;

    const method = method_ptr[0..method_len];
    const target = path_ptr[0..path_len];
    var parsed: ParsedRequest = .{
        .method = method,
        .target = target,
        .minor_version = minor_version,
        .keep_alive = minor_version >= 1,
        .header_bytes = @intCast(rc),
    };

    for (headers[0..num_headers]) |header| {
        const name = header.name[0..header.name_len];
        const value = header.value[0..header.value_len];
        if (std.ascii.eqlIgnoreCase(name, "connection")) {
            parsed.keep_alive = !std.ascii.eqlIgnoreCase(value, "close");
        } else if (std.ascii.eqlIgnoreCase(name, "content-type")) {
            parsed.content_type = value;
        } else if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            parsed.content_length = std.fmt.parseInt(u64, value, 10) catch return error.MalformedRequest;
        }
    }

    return parsed;
}

pub fn writeResponse(writer_io: *std.Io.Writer, response: http.HttpResponse, keep_alive: bool, skip_body: bool) !void {
    var buffer: [1024]u8 = undefined;
    var writer: FixedBufferWriter = .init(&buffer);

    try serializeHead(&writer, response, keep_alive);

    const head = writer.written();
    if (skip_body or response.body.len == 0) {
        try writer_io.writeAll(head);
        try writer_io.flush();
        return;
    }

    if (writer.remaining() >= response.body.len) {
        try writer.writeAll(response.body);
        try writer_io.writeAll(writer.written());
        try writer_io.flush();
        return;
    }

    var bufs: [2][]const u8 = .{ head, response.body };
    try writer_io.writeVecAll(&bufs);
    try writer_io.flush();
}

pub fn writeError(writer_io: *std.Io.Writer, status: http.HttpStatus, body: []const u8) void {
    writeResponse(writer_io, .{ .status = status, .body = body }, false, false) catch {};
}

fn reasonPhrase(status: http.HttpStatus) []const u8 {
    return switch (status) {
        .ok => "OK",
        .created => "Created",
        .no_content => "No Content",
        .bad_request => "Bad Request",
        .not_found => "Not Found",
        .method_not_allowed => "Method Not Allowed",
        .payload_too_large => "Payload Too Large",
        .internal_server_error => "Internal Server Error",
    };
}

fn serializeHead(writer: *FixedBufferWriter, response: http.HttpResponse, keep_alive: bool) !void {
    if (response.status == .ok) {
        try writer.writeAll("HTTP/1.1 200 OK\r\n");
    } else {
        try writer.print("HTTP/1.1 {d} {s}\r\n", .{ @intFromEnum(response.status), reasonPhrase(response.status) });
    }

    try writer.print("content-length: {d}\r\n", .{response.body.len});
    try writer.writeAll("content-type: ");
    try writer.writeAll(response.content_type);
    try writer.writeAll("\r\n");
    try writer.writeAll(if (keep_alive) "connection: keep-alive\r\n" else "connection: close\r\n");

    for (response.extra_headers) |header| {
        try writer.writeAll(header.name);
        try writer.writeAll(": ");
        try writer.writeAll(header.value);
        try writer.writeAll("\r\n");
    }

    try writer.writeAll("\r\n");
}

const FixedBufferWriter = struct {
    buffer: []u8,
    len: usize = 0,

    fn init(buffer: []u8) FixedBufferWriter {
        return .{ .buffer = buffer };
    }

    fn written(self: *const FixedBufferWriter) []const u8 {
        return self.buffer[0..self.len];
    }

    fn remaining(self: *const FixedBufferWriter) usize {
        return self.buffer.len - self.len;
    }

    fn writeAll(self: *FixedBufferWriter, bytes: []const u8) !void {
        if (bytes.len > self.remaining()) return error.NoSpaceLeft;
        @memcpy(self.buffer[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
    }

    fn print(self: *FixedBufferWriter, comptime fmt: []const u8, args: anytype) !void {
        const out = try std.fmt.bufPrint(self.buffer[self.len..], fmt, args);
        self.len += out.len;
    }
};

test "pico parser parses request" {
    var buf = "GET /hello?x=1 HTTP/1.1\r\nhost: example\r\n\r\n".*;
    const parsed = (try parse(&buf, 0)).?;
    try std.testing.expectEqualStrings("GET", parsed.method);
    try std.testing.expectEqualStrings("/hello?x=1", parsed.target);
}
