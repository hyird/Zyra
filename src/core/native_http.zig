const std = @import("std");
const zio = @import("zio");
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

    pub fn readHead(self: *SessionBuffer, stream: zio.net.Stream, max_header_size: usize) !ParsedRequest {
        var previous_len: usize = 0;

        while (true) {
            if (self.used > previous_len) {
                if (try parse(self.buf[0..self.used], previous_len)) |parsed| return parsed;
                previous_len = self.used;
            }

            if (self.used >= self.buf.len) return error.HeaderTooLarge;
            if (self.used >= max_header_size) return error.HeaderTooLarge;

            const n = try stream.read(self.buf[self.used..], .none);
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

pub fn writeResponse(stream: zio.net.Stream, response: http.HttpResponse, keep_alive: bool, skip_body: bool) !void {
    var header_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&header_buf);

    try out.print("HTTP/1.1 {d} {s}\r\n", .{ @intFromEnum(response.status), reasonPhrase(response.status) });
    try out.print("content-length: {d}\r\n", .{if (skip_body) 0 else response.body.len});
    try out.print("content-type: {s}\r\n", .{response.content_type});
    try out.writeAll(if (keep_alive) "connection: keep-alive\r\n" else "connection: close\r\n");
    for (response.extra_headers) |header| {
        try out.print("{s}: {s}\r\n", .{ header.name, header.value });
    }
    try out.writeAll("\r\n");

    try stream.writeAll(out.buffered(), .none);
    if (!skip_body and response.body.len > 0) try stream.writeAll(response.body, .none);
}

pub fn writeError(stream: zio.net.Stream, status: http.HttpStatus, body: []const u8) void {
    writeResponse(stream, .{ .status = status, .body = body }, false, false) catch {};
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

test "pico parser parses request" {
    var buf = "GET /hello?x=1 HTTP/1.1\r\nhost: example\r\n\r\n".*;
    const parsed = (try parse(&buf, 0)).?;
    try std.testing.expectEqualStrings("GET", parsed.method);
    try std.testing.expectEqualStrings("/hello?x=1", parsed.target);
}
