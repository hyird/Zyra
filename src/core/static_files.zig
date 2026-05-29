//! Static file serving.
//!
//! `StaticFiles` maps a URL prefix onto a local directory and serves files with
//! MIME detection, ETag / If-None-Match (304), HTTP Range requests (206/416),
//! and path-traversal protection. The pure helpers (`mimeType`, `makeEtag`,
//! `parseByteRange`, `isSafeRelPath`) are independently testable; actual file
//! I/O uses the runtime `std.Io` carried by the request.

const std = @import("std");
const http = @import("http.zig");

/// Returns the MIME type for a file extension (including the leading dot).
pub fn mimeType(ext: []const u8) []const u8 {
    const table = [_]struct { ext: []const u8, mime: []const u8 }{
        .{ .ext = ".html", .mime = "text/html; charset=utf-8" },
        .{ .ext = ".htm", .mime = "text/html; charset=utf-8" },
        .{ .ext = ".css", .mime = "text/css; charset=utf-8" },
        .{ .ext = ".js", .mime = "application/javascript; charset=utf-8" },
        .{ .ext = ".mjs", .mime = "application/javascript; charset=utf-8" },
        .{ .ext = ".json", .mime = "application/json; charset=utf-8" },
        .{ .ext = ".xml", .mime = "application/xml; charset=utf-8" },
        .{ .ext = ".txt", .mime = "text/plain; charset=utf-8" },
        .{ .ext = ".md", .mime = "text/markdown; charset=utf-8" },
        .{ .ext = ".svg", .mime = "image/svg+xml" },
        .{ .ext = ".png", .mime = "image/png" },
        .{ .ext = ".jpg", .mime = "image/jpeg" },
        .{ .ext = ".jpeg", .mime = "image/jpeg" },
        .{ .ext = ".gif", .mime = "image/gif" },
        .{ .ext = ".webp", .mime = "image/webp" },
        .{ .ext = ".ico", .mime = "image/x-icon" },
        .{ .ext = ".woff", .mime = "font/woff" },
        .{ .ext = ".woff2", .mime = "font/woff2" },
        .{ .ext = ".ttf", .mime = "font/ttf" },
        .{ .ext = ".otf", .mime = "font/otf" },
        .{ .ext = ".pdf", .mime = "application/pdf" },
        .{ .ext = ".zip", .mime = "application/zip" },
        .{ .ext = ".gz", .mime = "application/gzip" },
        .{ .ext = ".mp4", .mime = "video/mp4" },
        .{ .ext = ".webm", .mime = "video/webm" },
        .{ .ext = ".mp3", .mime = "audio/mpeg" },
        .{ .ext = ".wav", .mime = "audio/wav" },
    };
    for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(ext, entry.ext)) return entry.mime;
    }
    return "application/octet-stream";
}

/// Builds a quoted ETag from file size and modification timestamp (nanoseconds).
pub fn makeEtag(buffer: []u8, file_size: u64, mtime_ns: i128) ![]const u8 {
    return std.fmt.bufPrint(buffer, "\"{d}-{d}\"", .{ file_size, mtime_ns });
}

pub const ByteRange = struct {
    start: u64,
    end: u64, // inclusive
};

pub const RangeResult = union(enum) {
    none, // no/invalid syntax but not unsatisfiable: serve full
    range: ByteRange,
    unsatisfiable, // valid syntax but out of bounds -> 416
    multi, // multi-range, not supported -> serve full
};

/// Parses a `Range` header value against `file_size`.
/// Supports `bytes=0-499`, `bytes=500-`, and `bytes=-500`.
pub fn parseByteRange(header: []const u8, file_size: u64) RangeResult {
    if (header.len < 7 or !std.mem.startsWith(u8, header, "bytes=")) return .none;
    const spec = header[6..];
    if (std.mem.indexOfScalar(u8, spec, ',') != null) return .multi;

    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return .none;
    const start_str = spec[0..dash];
    const end_str = spec[dash + 1 ..];
    if (file_size == 0) return .unsatisfiable;

    var start: u64 = 0;
    var end: u64 = file_size - 1;

    if (start_str.len == 0) {
        // Suffix form "bytes=-N": last N bytes.
        if (end_str.len == 0) return .none;
        const suffix = std.fmt.parseInt(u64, end_str, 10) catch return .none;
        if (suffix == 0) return .unsatisfiable;
        start = if (suffix >= file_size) 0 else file_size - suffix;
        end = file_size - 1;
    } else {
        start = std.fmt.parseInt(u64, start_str, 10) catch return .none;
        if (end_str.len != 0) {
            end = std.fmt.parseInt(u64, end_str, 10) catch return .none;
        }
    }

    if (end >= file_size) end = file_size - 1;
    if (start > end or start >= file_size) return .unsatisfiable;
    return .{ .range = .{ .start = start, .end = end } };
}

/// Validates a request-relative path, rejecting traversal (`..`), absolute
/// paths, and Windows drive/backslash tricks. Returns the cleaned relative path
/// (leading slashes trimmed) or null if unsafe.
pub fn isSafeRelPath(path: []const u8) ?[]const u8 {
    var rel = path;
    while (rel.len > 0 and rel[0] == '/') rel = rel[1..];

    if (rel.len == 0) return rel;
    // Reject NUL and backslashes outright.
    if (std.mem.indexOfScalar(u8, rel, 0) != null) return null;
    if (std.mem.indexOfScalar(u8, rel, '\\') != null) return null;

    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) return null;
        if (std.mem.eql(u8, segment, ".")) return null;
    }
    return rel;
}

pub const StaticFiles = struct {
    root: []const u8,
    url_prefix: []const u8,
    max_file_size: u64 = 64 * 1024 * 1024,

    pub fn init(root: []const u8, url_prefix: []const u8) StaticFiles {
        return .{ .root = root, .url_prefix = url_prefix };
    }

    /// Resolves the request path to a relative file path under `root`, applying
    /// the URL prefix and traversal protection. Returns null if unsafe.
    pub fn resolveRelPath(self: StaticFiles, request_path: []const u8) ?[]const u8 {
        var p = request_path;
        if (std.mem.startsWith(u8, p, self.url_prefix)) {
            p = p[self.url_prefix.len ..];
        }
        return isSafeRelPath(p);
    }

    /// Serves the file referenced by `req`. Requires `req.io` to be set.
    pub fn serve(self: StaticFiles, req: *http.HttpRequest) !http.HttpResponse {
        const io = req.io orelse return http.HttpResponse.serverError();
        const allocator = req.allocator;

        const rel = self.resolveRelPath(req.path) orelse {
            const res = http.HttpResponse{ .status = .forbidden, .body = "403 Forbidden" };
            return res;
        };

        // Build the on-disk path: root + "/" + rel (or root + "/index.html").
        const effective_rel = if (rel.len == 0) "index.html" else rel;
        const disk_path = try std.fs.path.join(allocator, &.{ self.root, effective_rel });

        var dir = std.Io.Dir.cwd();
        var file = dir.openFile(io, disk_path, .{}) catch {
            return http.HttpResponse.notFound();
        };
        defer file.close(io);

        const stat = file.stat(io) catch return http.HttpResponse.serverError();
        if (stat.kind == .directory) {
            return http.HttpResponse.notFound();
        }
        const file_size = stat.size;
        if (file_size > self.max_file_size) {
            return http.HttpResponse{ .status = .payload_too_large, .body = "413 File Too Large" };
        }

        const mtime_ns: i128 = @intCast(stat.mtime.nanoseconds);
        var etag_buf: [48]u8 = undefined;
        const etag = try makeEtag(&etag_buf, file_size, mtime_ns);
        const etag_owned = try allocator.dupe(u8, etag);

        const ext = std.fs.path.extension(effective_rel);
        const mime = mimeType(ext);

        // 304 Not Modified.
        if (req.header("if-none-match")) |inm| {
            if (std.mem.eql(u8, inm, etag_owned)) {
                var res = http.HttpResponse{ .status = .not_modified, .body = "" };
                try res.setHeader("etag", etag_owned);
                return res;
            }
        }

        // Range handling.
        if (req.header("range")) |range_header| {
            const if_range = req.header("if-range");
            const range_valid = if_range == null or std.mem.eql(u8, if_range.?, etag_owned);
            if (range_valid) {
                switch (parseByteRange(range_header, file_size)) {
                    .unsatisfiable => return http.HttpResponse.rangeNotSatisfiable(file_size),
                    .range => |r| {
                        const len: usize = @intCast(r.end - r.start + 1);
                        const buf = try allocator.alloc(u8, len);
                        const read = file.readPositionalAll(io, buf, r.start) catch return http.HttpResponse.serverError();
                        var res = http.HttpResponse{ .status = .partial_content, .body = buf[0..read], .content_type = mime };
                        res.setContentRange(r.start, r.end, file_size);
                        try res.setHeader("accept-ranges", "bytes");
                        try res.setHeader("etag", etag_owned);
                        try res.setHeader("x-content-type-options", "nosniff");
                        return res;
                    },
                    .none, .multi => {}, // fall through to full response
                }
            }
        }

        // Full 200 response.
        const buf = try allocator.alloc(u8, @intCast(file_size));
        const read = file.readPositionalAll(io, buf, 0) catch return http.HttpResponse.serverError();
        var res = http.HttpResponse{ .status = .ok, .body = buf[0..read], .content_type = mime };
        try res.setHeader("accept-ranges", "bytes");
        try res.setHeader("etag", etag_owned);
        try res.setHeader("x-content-type-options", "nosniff");
        return res;
    }
};

test "mimeType maps extensions" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", mimeType(".html"));
    try std.testing.expectEqualStrings("image/png", mimeType(".PNG"));
    try std.testing.expectEqualStrings("application/octet-stream", mimeType(".unknown"));
}

test "makeEtag formats size and mtime" {
    var buf: [48]u8 = undefined;
    try std.testing.expectEqualStrings("\"100-12345\"", try makeEtag(&buf, 100, 12345));
}

test "parseByteRange handles closed open and suffix forms" {
    try std.testing.expectEqual(ByteRange{ .start = 0, .end = 499 }, parseByteRange("bytes=0-499", 1000).range);
    try std.testing.expectEqual(ByteRange{ .start = 500, .end = 999 }, parseByteRange("bytes=500-", 1000).range);
    try std.testing.expectEqual(ByteRange{ .start = 500, .end = 999 }, parseByteRange("bytes=-500", 1000).range);
    try std.testing.expectEqual(ByteRange{ .start = 990, .end = 999 }, parseByteRange("bytes=990-2000", 1000).range);
}

test "parseByteRange flags unsatisfiable multi and none" {
    try std.testing.expectEqual(RangeResult.unsatisfiable, parseByteRange("bytes=2000-3000", 1000));
    try std.testing.expectEqual(RangeResult.multi, parseByteRange("bytes=0-1,2-3", 1000));
    try std.testing.expectEqual(RangeResult.none, parseByteRange("items=0-1", 1000));
}

test "isSafeRelPath blocks traversal and absolute tricks" {
    try std.testing.expectEqualStrings("a/b.txt", isSafeRelPath("/a/b.txt").?);
    try std.testing.expectEqualStrings("", isSafeRelPath("/").?);
    try std.testing.expect(isSafeRelPath("../etc/passwd") == null);
    try std.testing.expect(isSafeRelPath("a/../../b") == null);
    try std.testing.expect(isSafeRelPath("a\\b") == null);
}

test "resolveRelPath strips url prefix" {
    const sf = StaticFiles.init("./public", "/static/");
    try std.testing.expectEqualStrings("app.js", sf.resolveRelPath("/static/app.js").?);
    try std.testing.expect(sf.resolveRelPath("/static/../secret") == null);
}
