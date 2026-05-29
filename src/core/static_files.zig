//! 静态文件服务。
//!
//! `StaticFiles` 把一个 URL 前缀映射到本地目录，并提供文件服务，支持 MIME
//! 检测、ETag / If-None-Match（304）、HTTP Range 请求（206/416）以及路径
//! 穿越防护。纯辅助函数（`mimeType`、`makeEtag`、`parseByteRange`、
//! `isSafeRelPath`）可独立测试；实际的文件 I/O 使用请求携带的运行时
//! `std.Io`。

const std = @import("std");
const http = @import("http.zig");

/// 返回文件扩展名（含前导点）对应的 MIME 类型。
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

/// 由文件大小和修改时间戳（纳秒）构建一个带引号的 ETag。
pub fn makeEtag(buffer: []u8, file_size: u64, mtime_ns: i128) ![]const u8 {
    return std.fmt.bufPrint(buffer, "\"{d}-{d}\"", .{ file_size, mtime_ns });
}

pub const ByteRange = struct {
    start: u64,
    end: u64, // 闭区间，含 end
};

pub const RangeResult = union(enum) {
    none, // 无/无效语法但并非不可满足：提供完整文件
    range: ByteRange,
    unsatisfiable, // 语法有效但越界 -> 416
    multi, // 多段范围，不支持 -> 提供完整文件
};

/// 针对 `file_size` 解析一个 `Range` 头部的值。
/// 支持 `bytes=0-499`、`bytes=500-` 和 `bytes=-500`。
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
        // 后缀形式 "bytes=-N"：取最后 N 个字节。
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

/// 校验一个相对请求路径，拒绝穿越（`..`）、绝对路径以及 Windows 盘符/
/// 反斜杠技巧。返回清理后的相对路径（去掉前导斜杠），不安全则返回 null。
pub fn isSafeRelPath(path: []const u8) ?[]const u8 {
    var rel = path;
    while (rel.len > 0 and rel[0] == '/') rel = rel[1..];

    if (rel.len == 0) return rel;
    // 直接拒绝 NUL 和反斜杠。
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
    /// 可选的路径解析缓存。设置后，会按相对请求路径缓存解析出的磁盘路径
    /// 以及最近一次的 size/mtime/etag/mime，缓存时长为 `cache_ttl_ns`，从而
    /// 让重复请求跳过 `path.join` + `stat` 的开销。
    cache: ?*PathCache = null,
    cache_ttl_ns: i128 = 60 * std.time.ns_per_s,

    pub fn init(root: []const u8, url_prefix: []const u8) StaticFiles {
        return .{ .root = root, .url_prefix = url_prefix };
    }

    /// 与 `init` 类似，但会分配一个路径解析缓存。返回值拥有该缓存；调用
    /// `deinit` 释放它。
    pub fn initCached(allocator: std.mem.Allocator, root: []const u8, url_prefix: []const u8) !StaticFiles {
        const cache = try allocator.create(PathCache);
        cache.* = PathCache.init(allocator);
        return .{ .root = root, .url_prefix = url_prefix, .cache = cache };
    }

    /// 释放路径解析缓存（若由 `initCached` 分配过）。
    pub fn deinit(self: *StaticFiles, allocator: std.mem.Allocator) void {
        if (self.cache) |cache| {
            cache.deinit();
            allocator.destroy(cache);
            self.cache = null;
        }
    }

    /// 单条缓存解析结果：磁盘路径以及缓存时观测到的文件元数据。
    /// `disk_path`/`etag`/`mime` 由缓存分配器拥有，在条目被驱逐前一直有效。
    pub const CacheEntry = struct {
        disk_path: []const u8,
        file_size: u64,
        mtime_ns: i128,
        etag: []const u8,
        mime: []const u8,
        cached_at_ns: i128,
        last_use: u64,
    };

    /// 按 `last_use` 做 LRU 的有界已解析路径缓存，由 `std.Io.Mutex` 保护，
    /// 使并发的请求 fiber 能安全共享。
    pub const PathCache = struct {
        allocator: std.mem.Allocator,
        mutex: std.Io.Mutex = .init,
        map: std.StringHashMapUnmanaged(CacheEntry) = .empty,
        tick: u64 = 0,

        pub const max_entries = 4096;

        pub fn init(allocator: std.mem.Allocator) PathCache {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *PathCache) void {
            var it = self.map.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.freeEntry(entry.value_ptr);
            }
            self.map.deinit(self.allocator);
        }

        fn freeEntry(self: *PathCache, entry: *CacheEntry) void {
            self.allocator.free(entry.disk_path);
            self.allocator.free(entry.etag);
            // `mime` 指向静态 `mimeType` 表 —— 非本缓存所有。
        }

        /// 驱逐 `last_use` 最小（最久未使用）的条目。
        fn evictOne(self: *PathCache) void {
            var it = self.map.iterator();
            var victim_key: ?[]const u8 = null;
            var min_use: u64 = std.math.maxInt(u64);
            while (it.next()) |entry| {
                if (entry.value_ptr.last_use < min_use) {
                    min_use = entry.value_ptr.last_use;
                    victim_key = entry.key_ptr.*;
                }
            }
            if (victim_key) |k| {
                if (self.map.fetchRemove(k)) |kv| {
                    self.allocator.free(kv.key);
                    var v = kv.value;
                    self.freeEntry(&v);
                }
            }
        }
    };

    /// 将请求路径解析为 `root` 下的相对文件路径，应用 URL 前缀并做穿越
    /// 防护。不安全则返回 null。
    pub fn resolveRelPath(self: StaticFiles, request_path: []const u8) ?[]const u8 {
        var p = request_path;
        if (std.mem.startsWith(u8, p, self.url_prefix)) {
            p = p[self.url_prefix.len ..];
        }
        return isSafeRelPath(p);
    }

    /// 提供 `req` 所引用的文件。要求已设置 `req.io`。
    pub fn serve(self: StaticFiles, req: *http.HttpRequest) !http.HttpResponse {
        const io = req.io orelse return http.HttpResponse.serverError();
        const allocator = req.allocator;

        const rel = self.resolveRelPath(req.path) orelse {
            const res = http.HttpResponse{ .status = .forbidden, .body = "403 Forbidden" };
            return res;
        };
        const effective_rel = if (rel.len == 0) "index.html" else rel;

        // 尝试路径解析缓存：若命中且条目仍新鲜，则复用解析出的磁盘路径与
        // 文件元数据，无需重新 stat。缓存的字符串会复制到请求 arena，因此即便
        // 之后该条目被并发驱逐，它们对本次响应仍然有效。
        if (self.cache) |cache| {
            const now = std.Io.Clock.now(.awake, io).nanoseconds;
            cache.mutex.lockUncancelable(io);
            const hit: ?CacheEntry = blk: {
                if (cache.map.getPtr(effective_rel)) |entry| {
                    if (now - entry.cached_at_ns < self.cache_ttl_ns) {
                        cache.tick += 1;
                        entry.last_use = cache.tick;
                        break :blk entry.*;
                    }
                }
                break :blk null;
            };
            if (hit) |entry| {
                const disk_path = try allocator.dupe(u8, entry.disk_path);
                const etag_owned = try allocator.dupe(u8, entry.etag);
                cache.mutex.unlock(io);
                return self.respondFor(req, disk_path, entry.file_size, etag_owned, entry.mime);
            }
            cache.mutex.unlock(io);
        }

        // 缓存未命中（或无缓存）：从磁盘解析 + stat。
        const disk_path = try std.fs.path.join(allocator, &.{ self.root, effective_rel });

        var dir = std.Io.Dir.cwd();
        var file = dir.openFile(io, disk_path, .{}) catch {
            return http.HttpResponse.notFound();
        };

        const stat = file.stat(io) catch {
            file.close(io);
            return http.HttpResponse.serverError();
        };
        file.close(io);
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

        // 为下次填充缓存（尽力而为；分配失败则直接不缓存）。
        if (self.cache) |cache| {
            self.cacheStore(cache, io, effective_rel, disk_path, file_size, mtime_ns, etag_owned, mime);
        }

        return self.respondFor(req, disk_path, file_size, etag_owned, mime);
    }

    /// 将一条新解析的条目存入缓存，满时驱逐 LRU 牺牲者。失败会被吞掉
    /// （缓存为尽力而为）。
    fn cacheStore(
        self: StaticFiles,
        cache: *PathCache,
        io: std.Io,
        rel: []const u8,
        disk_path: []const u8,
        file_size: u64,
        mtime_ns: i128,
        etag: []const u8,
        mime: []const u8,
    ) void {
        _ = self;
        cache.mutex.lockUncancelable(io);
        defer cache.mutex.unlock(io);

        // 就地刷新已有条目。
        if (cache.map.getPtr(rel)) |entry| {
            cache.allocator.free(entry.disk_path);
            cache.allocator.free(entry.etag);
            entry.disk_path = cache.allocator.dupe(u8, disk_path) catch return;
            entry.etag = cache.allocator.dupe(u8, etag) catch return;
            entry.file_size = file_size;
            entry.mtime_ns = mtime_ns;
            entry.mime = mime;
            entry.cached_at_ns = std.Io.Clock.now(.awake, io).nanoseconds;
            cache.tick += 1;
            entry.last_use = cache.tick;
            return;
        }

        if (cache.map.count() >= PathCache.max_entries) cache.evictOne();

        const key = cache.allocator.dupe(u8, rel) catch return;
        const path_copy = cache.allocator.dupe(u8, disk_path) catch {
            cache.allocator.free(key);
            return;
        };
        const etag_copy = cache.allocator.dupe(u8, etag) catch {
            cache.allocator.free(key);
            cache.allocator.free(path_copy);
            return;
        };
        cache.tick += 1;
        cache.map.put(cache.allocator, key, .{
            .disk_path = path_copy,
            .file_size = file_size,
            .mtime_ns = mtime_ns,
            .etag = etag_copy,
            .mime = mime,
            .cached_at_ns = std.Io.Clock.now(.awake, io).nanoseconds,
            .last_use = cache.tick,
        }) catch {
            cache.allocator.free(key);
            cache.allocator.free(path_copy);
            cache.allocator.free(etag_copy);
        };
    }

    /// 根据已解析的元数据构建实际的 HTTP 响应（304 / 206 / 200）。
    /// 所有切片参数的生命周期都必须长于响应（请求 arena 的生命周期）。
    fn respondFor(
        self: StaticFiles,
        req: *http.HttpRequest,
        disk_path: []const u8,
        file_size: u64,
        etag_owned: []const u8,
        mime: []const u8,
    ) !http.HttpResponse {
        _ = self;

        // 304 Not Modified。
        if (req.header("if-none-match")) |inm| {
            if (std.mem.eql(u8, inm, etag_owned)) {
                var res = http.HttpResponse{ .status = .not_modified, .body = "" };
                try res.setHeader("etag", etag_owned);
                return res;
            }
        }

        // Range 处理。
        if (req.header("range")) |range_header| {
            const if_range = req.header("if-range");
            const range_valid = if_range == null or std.mem.eql(u8, if_range.?, etag_owned);
            if (range_valid) {
                switch (parseByteRange(range_header, file_size)) {
                    .unsatisfiable => return http.HttpResponse.rangeNotSatisfiable(file_size),
                    .range => |r| {
                        const len: u64 = r.end - r.start + 1;
                        // 从磁盘流式传输请求的范围（常量内存）。
                        var res = http.HttpResponse.fileBody(.partial_content, mime, disk_path, r.start, len);
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

        // Full 200 response, streamed from disk in chunks (constant memory).
        var res = http.HttpResponse.fileBody(.ok, mime, disk_path, 0, file_size);
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

const zio = @import("zio");

const SmokeState = struct {
    io: std.Io,
    dir: []const u8,
    arena: std.mem.Allocator,
    err: ?anyerror = null,
    full_status: http.HttpStatus = .internal_server_error,
    full_len: u64 = 0,
    full_path: []const u8 = "",
    full_etag: []const u8 = "",
    notmod_status: http.HttpStatus = .internal_server_error,
    range_status: http.HttpStatus = .internal_server_error,
    range_offset: u64 = 0,
    range_len: u64 = 0,
    range_content_range_present: bool = false,
    notfound_status: http.HttpStatus = .ok,
    cache_hit_len: u64 = 0,
    cache_hit_status: http.HttpStatus = .internal_server_error,
    cache_entries: usize = 0,
};

fn smokeRun(state: *SmokeState) std.Io.Cancelable!void {
    smokeImpl(state) catch |err| {
        state.err = err;
    };
}

fn smokeImpl(state: *SmokeState) anyerror!void {
    const io = state.io;

    // Create a temp dir + file using the same std.Io backend serve() reads.
    var cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, state.dir) catch {};
    try cwd.createDirPath(io, state.dir);
    defer cwd.deleteTree(io, state.dir) catch {};

    const file_rel = try std.fmt.allocPrint(state.arena, "{s}/hello.txt", .{state.dir});
    {
        // zio's std.Io backend supports positional file writes (not streaming).
        var f = try cwd.createFile(io, file_rel, .{});
        defer f.close(io);
        try f.writePositionalAll(io, "Hello, Zyra!", 0);
    }

    const sf = StaticFiles.init(state.dir, "/static/");

    // Full 200 response.
    var req_full = http.HttpRequest{
        .allocator = state.arena,
        .method = .get,
        .path = "/static/hello.txt",
        .target = "/static/hello.txt",
        .io = state.io,
    };
    const full = try sf.serve(&req_full);
    state.full_status = full.status;
    if (full.file) |fb| {
        state.full_len = fb.length;
        state.full_path = fb.path;
    }
    state.full_etag = full.header("etag") orelse "";

    // 304 Not Modified using the returned ETag.
    var req_nm = http.HttpRequest{
        .allocator = state.arena,
        .method = .get,
        .path = "/static/hello.txt",
        .target = "/static/hello.txt",
        .io = state.io,
    };
    try req_nm.addHeader("if-none-match", state.full_etag);
    const nm = try sf.serve(&req_nm);
    state.notmod_status = nm.status;

    // 206 Partial Content via Range.
    var req_rg = http.HttpRequest{
        .allocator = state.arena,
        .method = .get,
        .path = "/static/hello.txt",
        .target = "/static/hello.txt",
        .io = state.io,
    };
    try req_rg.addHeader("range", "bytes=0-4");
    const rg = try sf.serve(&req_rg);
    state.range_status = rg.status;
    if (rg.file) |fb| {
        state.range_offset = fb.offset;
        state.range_len = fb.length;
    }
    state.range_content_range_present = rg.content_range_len > 0;

    // 404 for a missing file.
    var req_nf = http.HttpRequest{
        .allocator = state.arena,
        .method = .get,
        .path = "/static/missing.txt",
        .target = "/static/missing.txt",
        .io = state.io,
    };
    const nf = try sf.serve(&req_nf);
    state.notfound_status = nf.status;

    // Cached StaticFiles: two requests for the same path; the second is a hit.
    var sf_cached = try StaticFiles.initCached(state.arena, state.dir, "/static/");
    defer sf_cached.deinit(state.arena);

    var req_c1 = http.HttpRequest{
        .allocator = state.arena,
        .method = .get,
        .path = "/static/hello.txt",
        .target = "/static/hello.txt",
        .io = state.io,
    };
    _ = try sf_cached.serve(&req_c1); // populates the cache

    var req_c2 = http.HttpRequest{
        .allocator = state.arena,
        .method = .get,
        .path = "/static/hello.txt",
        .target = "/static/hello.txt",
        .io = state.io,
    };
    const c2 = try sf_cached.serve(&req_c2); // cache hit
    state.cache_hit_status = c2.status;
    if (c2.file) |fb| state.cache_hit_len = fb.length;
    state.cache_entries = sf_cached.cache.?.map.count();
}

fn smokeRoot(state: *SmokeState) anyerror!void {
    const io = state.io;
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, smokeRun, .{state});
    group.await(io) catch {};
}

test "static files end-to-end serve 200 304 206 404" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var runtime = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();
    const io = runtime.io();

    var state = SmokeState{ .io = io, .dir = "zig-cache-zyra-static-smoke", .arena = arena };
    try smokeRoot(&state);

    if (state.err) |err| return err;

    try std.testing.expectEqual(http.HttpStatus.ok, state.full_status);
    try std.testing.expectEqual(@as(u64, 12), state.full_len); // "Hello, Zyra!"
    try std.testing.expect(state.full_path.len > 0);
    try std.testing.expect(state.full_etag.len > 0);

    try std.testing.expectEqual(http.HttpStatus.not_modified, state.notmod_status);

    try std.testing.expectEqual(http.HttpStatus.partial_content, state.range_status);
    try std.testing.expectEqual(@as(u64, 0), state.range_offset);
    try std.testing.expectEqual(@as(u64, 5), state.range_len); // bytes=0-4
    try std.testing.expect(state.range_content_range_present);

    try std.testing.expectEqual(http.HttpStatus.not_found, state.notfound_status);

    // Cached path: hit returns the same file length and leaves one cache entry.
    try std.testing.expectEqual(http.HttpStatus.ok, state.cache_hit_status);
    try std.testing.expectEqual(@as(u64, 12), state.cache_hit_len);
    try std.testing.expectEqual(@as(usize, 1), state.cache_entries);
}
