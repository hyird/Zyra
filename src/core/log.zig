//! Structured logging.
//!
//! A focused, fully-implemented subset of Hical's logging stack:
//!
//! - `Level`        - severity levels with text labels and ordering
//! - `Field`        - a structured key/value pair (string values)
//! - `Sink`         - transport-agnostic line sink (function pointer + context)
//! - `writerSink`   - adapts any `*std.Io.Writer` into a `Sink`
//! - `Logger`       - level-filtered, structured line logger
//! - `LogMiddleware`- context-onion middleware that logs each request's method,
//!   path, status, and duration
//!
//! Lines are formatted as:
//!   `LEVEL message key1=value1 key2=value2`
//! Logging below the configured minimum level is skipped before any formatting.

const std = @import("std");
const http = @import("http.zig");
const middleware = @import("middleware.zig");

pub const Level = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,

    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }

    /// Parses a level label (case-insensitive). Accepts the canonical labels
    /// (`DEBUG`/`INFO`/`WARN`/`ERROR`) as well as the alias `WARNING`.
    pub fn fromLabel(text: []const u8) ?Level {
        if (std.ascii.eqlIgnoreCase(text, "debug")) return .debug;
        if (std.ascii.eqlIgnoreCase(text, "info")) return .info;
        if (std.ascii.eqlIgnoreCase(text, "warn") or std.ascii.eqlIgnoreCase(text, "warning")) return .warn;
        if (std.ascii.eqlIgnoreCase(text, "error") or std.ascii.eqlIgnoreCase(text, "err")) return .err;
        return null;
    }
};

/// A structured log field. Values are strings; format numbers with the caller's
/// own buffer before passing them in.
pub const Field = struct {
    key: []const u8,
    value: []const u8,
};

/// Line sink. `write` receives a fully-formatted line WITHOUT a trailing
/// newline; the sink decides line termination. Errors are reported back to the
/// logger, which swallows them (logging must never crash the caller).
pub const Sink = struct {
    ptr: *anyopaque,
    writeFn: *const fn (*anyopaque, []const u8) anyerror!void,

    fn write(self: Sink, line: []const u8) void {
        self.writeFn(self.ptr, line) catch {};
    }
};

/// Adapts any `*std.Io.Writer` into a `Sink`. The writer must outlive the sink.
/// A newline is appended after each line. Note: the caller is responsible for
/// flushing the underlying writer.
pub fn writerSink(writer: *std.Io.Writer) Sink {
    const Adapter = struct {
        fn write(ptr: *anyopaque, line: []const u8) anyerror!void {
            const w: *std.Io.Writer = @ptrCast(@alignCast(ptr));
            try w.writeAll(line);
            try w.writeByte('\n');
        }
    };
    return .{ .ptr = writer, .writeFn = Adapter.write };
}

/// A `Sink` that appends log lines to a file using the `std.Io` file API.
///
/// Each line is written with a trailing newline at the current end offset, so
/// concurrent loggers writing to distinct `FileSink`s never interleave within a
/// line. The file is created (and, by default, truncated) on `open`; pass
/// `.{ .truncate = false }` to keep and append after any existing content.
///
/// `FileSink` owns the underlying `std.Io.File` and must be closed with
/// `close`. It must outlive any `Logger` built from its `sink()`.
pub const FileSink = struct {
    io: std.Io,
    file: std.Io.File,
    offset: u64,

    pub const OpenOptions = struct {
        /// Truncate an existing file to zero length on open. When false, the
        /// sink appends after the current contents.
        truncate: bool = true,
    };

    /// Creates or opens `path` for appending log lines. `path` is resolved
    /// relative to the current working directory via `std.Io.Dir.cwd()`.
    pub fn open(io: std.Io, path: []const u8, options: OpenOptions) !FileSink {
        var dir = std.Io.Dir.cwd();
        const file = try dir.createFile(io, path, .{ .truncate = options.truncate });
        var offset: u64 = 0;
        if (!options.truncate) {
            const st = file.stat(io) catch |e| {
                file.close(io);
                return e;
            };
            offset = st.size;
        }
        return .{ .io = io, .file = file, .offset = offset };
    }

    pub fn close(self: *FileSink) void {
        self.file.close(self.io);
    }

    fn write(ptr: *anyopaque, line: []const u8) anyerror!void {
        const self: *FileSink = @ptrCast(@alignCast(ptr));
        try self.file.writePositionalAll(self.io, line, self.offset);
        self.offset += line.len;
        try self.file.writePositionalAll(self.io, "\n", self.offset);
        self.offset += 1;
    }

    pub fn sink(self: *FileSink) Sink {
        return .{ .ptr = self, .writeFn = write };
    }
};

pub const Logger = struct {
    sink: Sink,
    min_level: Level = .info,

    pub fn init(sink: Sink, min_level: Level) Logger {
        return .{ .sink = sink, .min_level = min_level };
    }

    pub fn enabled(self: *const Logger, level: Level) bool {
        return @intFromEnum(level) >= @intFromEnum(self.min_level);
    }

    /// Logs a message with optional structured fields at `level`. Formatting is
    /// skipped entirely when `level` is below the minimum. The formatted line is
    /// built on a fixed 1 KiB stack buffer; longer lines are truncated.
    pub fn log(self: *const Logger, level: Level, message: []const u8, fields: []const Field) void {
        if (!self.enabled(level)) return;

        var buf: [1024]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.writeAll(level.label()) catch {};
        w.writeByte(' ') catch {};
        w.writeAll(message) catch {};
        for (fields) |field| {
            w.writeByte(' ') catch {};
            w.writeAll(field.key) catch {};
            w.writeByte('=') catch {};
            w.writeAll(field.value) catch {};
        }
        self.sink.write(buf[0..w.end]);
    }

    pub fn debug(self: *const Logger, message: []const u8, fields: []const Field) void {
        self.log(.debug, message, fields);
    }
    pub fn info(self: *const Logger, message: []const u8, fields: []const Field) void {
        self.log(.info, message, fields);
    }
    pub fn warn(self: *const Logger, message: []const u8, fields: []const Field) void {
        self.log(.warn, message, fields);
    }
    pub fn err(self: *const Logger, message: []const u8, fields: []const Field) void {
        self.log(.err, message, fields);
    }
};

/// A named logging channel with its own runtime-adjustable level and sink.
///
/// Channels route categories of logs (e.g. `access`, `audit`, `perf`) to
/// distinct destinations and let operators tune each category's verbosity
/// independently. The level is stored atomically so it can be changed at
/// runtime (e.g. via the log-admin endpoints) while requests are logging.
pub const LogChannel = struct {
    name: []const u8,
    sink: Sink,
    level_raw: std.atomic.Value(u8),

    pub fn init(name: []const u8, sink: Sink, min_level: Level) LogChannel {
        return .{ .name = name, .sink = sink, .level_raw = .init(@intFromEnum(min_level)) };
    }

    pub fn level(self: *const LogChannel) Level {
        return @enumFromInt(self.level_raw.load(.acquire));
    }

    pub fn setLevel(self: *LogChannel, new_level: Level) void {
        self.level_raw.store(@intFromEnum(new_level), .release);
    }

    pub fn enabled(self: *const LogChannel, lvl: Level) bool {
        return @intFromEnum(lvl) >= self.level_raw.load(.acquire);
    }

    /// Emits a structured line on this channel, filtered by the channel's
    /// current level. Formatting matches `Logger.log` and is skipped entirely
    /// below the threshold.
    pub fn emit(self: *const LogChannel, lvl: Level, message: []const u8, fields: []const Field) void {
        if (!self.enabled(lvl)) return;
        var buf: [1024]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.writeAll(lvl.label()) catch {};
        w.writeByte(' ') catch {};
        w.writeAll(message) catch {};
        for (fields) |field| {
            w.writeByte(' ') catch {};
            w.writeAll(field.key) catch {};
            w.writeByte('=') catch {};
            w.writeAll(field.value) catch {};
        }
        self.sink.write(buf[0..w.end]);
    }
};

/// Thread-safe registry of named `LogChannel`s.
///
/// Channels are typically created at startup and looked up by name at runtime.
/// The registry owns each channel (heap-allocated) and frees them on `deinit`.
/// Channel names are duplicated into registry-owned storage. A mutex guards the
/// map; per-channel level changes use the channel's own atomic and need no lock.
pub const LogChannelRegistry = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    channels: std.StringHashMapUnmanaged(*LogChannel) = .empty,

    pub fn init(allocator: std.mem.Allocator) LogChannelRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *LogChannelRegistry) void {
        var it = self.channels.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.channels.deinit(self.allocator);
    }

    /// Returns the existing channel named `name`, or creates one with `sink`
    /// and `min_level`. The returned pointer is stable for the registry's
    /// lifetime. `io` is required for mutex locking.
    pub fn getOrCreate(
        self: *LogChannelRegistry,
        io: std.Io,
        name: []const u8,
        sink: Sink,
        min_level: Level,
    ) !*LogChannel {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.channels.get(name)) |existing| return existing;

        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        const channel = try self.allocator.create(LogChannel);
        errdefer self.allocator.destroy(channel);
        channel.* = LogChannel.init(name_copy, sink, min_level);
        try self.channels.put(self.allocator, name_copy, channel);
        return channel;
    }

    /// Returns the channel named `name`, or null if absent.
    pub fn get(self: *LogChannelRegistry, io: std.Io, name: []const u8) ?*LogChannel {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.channels.get(name);
    }

    /// Calls `callback(ctx, channel)` for each registered channel while holding
    /// the registry lock. Use for read-only iteration (e.g. listing levels).
    pub fn forEach(
        self: *LogChannelRegistry,
        io: std.Io,
        ctx: anytype,
        comptime callback: fn (@TypeOf(ctx), *LogChannel) anyerror!void,
    ) anyerror!void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var it = self.channels.iterator();
        while (it.next()) |entry| {
            try callback(ctx, entry.value_ptr.*);
        }
    }
};


/// `attach(server)` or `server.useOnionCtx(&mw, LogMiddleware.handle)`. Logs one
/// line per request: method, path, status, and duration in microseconds.
pub const LogMiddleware = struct {
    logger: *const Logger,

    pub fn init(logger: *const Logger) LogMiddleware {
        return .{ .logger = logger };
    }

    pub fn attach(self: *LogMiddleware, server: anytype) !void {
        try server.useOnionCtx(self, handle);
    }

    pub fn handle(ctx: *anyopaque, req: *http.HttpRequest, next: *middleware.Next) anyerror!http.HttpResponse {
        const self: *LogMiddleware = @ptrCast(@alignCast(ctx));
        const start_ns: ?i96 = if (req.io) |io|
            std.Io.Clock.now(.awake, io).nanoseconds
        else
            null;

        const response = try next.run(req);

        const elapsed_us: u64 = if (start_ns) |start| blk: {
            const io = req.io.?;
            const end = std.Io.Clock.now(.awake, io).nanoseconds;
            break :blk @intCast(@divTrunc(end - start, std.time.ns_per_us));
        } else 0;

        var status_buf: [4]u8 = undefined;
        const status_str = std.fmt.bufPrint(&status_buf, "{d}", .{@intFromEnum(response.status)}) catch "?";
        var dur_buf: [20]u8 = undefined;
        const dur_str = std.fmt.bufPrint(&dur_buf, "{d}", .{elapsed_us}) catch "?";

        const level: Level = if (@intFromEnum(response.status) >= 500) .err else .info;
        self.logger.log(level, "request", &.{
            .{ .key = "method", .value = @tagName(req.method) },
            .{ .key = "path", .value = req.path },
            .{ .key = "status", .value = status_str },
            .{ .key = "dur_us", .value = dur_str },
        });
        return response;
    }
};

/// Optional authentication check for the log-admin endpoints. Return `null` to
/// allow the request; return a response (e.g. 401/403) to reject it.
pub const AdminAuthCheck = *const fn (*http.HttpRequest) anyerror!?http.HttpResponse;

/// Runtime log-level administration as a context middleware.
///
/// Intercepts two endpoints under `prefix` (default `/admin`):
///   - `GET  {prefix}/log-level`  -> JSON `{ "channels": { name: "LEVEL", ... } }`
///   - `PUT  {prefix}/log-level`  -> body `{ "channel": "access", "level": "WARN" }`
///     adjusts a single channel's level; responds 200 on success, 400 on bad
///     input, 404 when the channel is unknown.
///
/// Requests to other paths are passed through to `next`. Register via
/// `attach(server)` (uses `server.useOnionCtx`).
///
/// WARNING: these endpoints mutate logging behavior. In production you MUST
/// supply an `auth` check to prevent unauthorized level changes.
pub const LogAdmin = struct {
    registry: *LogChannelRegistry,
    prefix: []const u8 = "/admin",
    auth: ?AdminAuthCheck = null,

    pub fn init(registry: *LogChannelRegistry) LogAdmin {
        return .{ .registry = registry };
    }

    pub fn attach(self: *LogAdmin, server: anytype) !void {
        try server.useOnionCtx(self, handle);
    }

    /// The endpoint path this admin instance handles (`{prefix}/log-level`).
    /// Computed on demand against a caller buffer to avoid allocation.
    fn matchesPath(self: *const LogAdmin, path: []const u8) bool {
        // path == prefix ++ "/log-level"
        if (!std.mem.startsWith(u8, path, self.prefix)) return false;
        const rest = path[self.prefix.len..];
        return std.mem.eql(u8, rest, "/log-level");
    }

    pub fn handle(ctx: *anyopaque, req: *http.HttpRequest, next: *middleware.Next) anyerror!http.HttpResponse {
        const self: *LogAdmin = @ptrCast(@alignCast(ctx));
        if (!self.matchesPath(req.path)) return next.run(req);

        if (self.auth) |auth| {
            if (try auth(req)) |denied| return denied;
        }

        return switch (req.method) {
            .get => self.handleGet(req),
            .put => self.handlePut(req),
            else => http.HttpResponse.methodNotAllowed("GET, PUT"),
        };
    }

    fn handleGet(self: *LogAdmin, req: *http.HttpRequest) anyerror!http.HttpResponse {
        const io = req.io orelse return http.HttpResponse.serverError();

        var out = std.Io.Writer.Allocating.init(req.allocator);
        defer out.deinit();
        var w = std.json.Stringify{ .writer = &out.writer };

        const Emit = struct {
            fn cb(writer: *std.json.Stringify, channel: *LogChannel) anyerror!void {
                try writer.objectField(channel.name);
                try writer.write(channel.level().label());
            }
        };

        try w.beginObject();
        try w.objectField("channels");
        try w.beginObject();
        try self.registry.forEach(io, &w, Emit.cb);
        try w.endObject();
        try w.endObject();

        const body = try out.toOwnedSlice();
        return http.HttpResponse.json(body);
    }

    const PutBody = struct { channel: []const u8, level: []const u8 };

    fn handlePut(self: *LogAdmin, req: *http.HttpRequest) anyerror!http.HttpResponse {
        const io = req.io orelse return http.HttpResponse.serverError();

        const parsed = req.readJson(PutBody) catch
            return http.HttpResponse.badRequest("invalid JSON body");

        const new_level = Level.fromLabel(parsed.level) orelse
            return http.HttpResponse.badRequest("unknown level");

        const channel = self.registry.get(io, parsed.channel) orelse
            return http.HttpResponse.notFound();

        channel.setLevel(new_level);
        return http.HttpResponse.json("{\"ok\":true}");
    }
};

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------


const router_mod = @import("router.zig");

/// Test sink that captures every line into an owned buffer.
const Capture = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayListUnmanaged([]u8) = .empty,

    fn init(allocator: std.mem.Allocator) Capture {
        return .{ .allocator = allocator };
    }
    fn deinit(self: *Capture) void {
        for (self.lines.items) |l| self.allocator.free(l);
        self.lines.deinit(self.allocator);
    }
    fn write(ptr: *anyopaque, line: []const u8) anyerror!void {
        const self: *Capture = @ptrCast(@alignCast(ptr));
        try self.lines.append(self.allocator, try self.allocator.dupe(u8, line));
    }
    fn sink(self: *Capture) Sink {
        return .{ .ptr = self, .writeFn = write };
    }
    fn last(self: *const Capture) ?[]const u8 {
        if (self.lines.items.len == 0) return null;
        return self.lines.items[self.lines.items.len - 1];
    }
};

test "level labels and ordering" {
    try std.testing.expectEqualStrings("DEBUG", Level.debug.label());
    try std.testing.expectEqualStrings("ERROR", Level.err.label());
    try std.testing.expect(@intFromEnum(Level.info) < @intFromEnum(Level.err));
}

test "logger formats structured fields" {
    var cap = Capture.init(std.testing.allocator);
    defer cap.deinit();
    const logger = Logger.init(cap.sink(), .debug);

    logger.info("hello", &.{ .{ .key = "user", .value = "alice" }, .{ .key = "ip", .value = "127.0.0.1" } });
    try std.testing.expectEqualStrings("INFO hello user=alice ip=127.0.0.1", cap.last().?);
}

test "logger respects minimum level" {
    var cap = Capture.init(std.testing.allocator);
    defer cap.deinit();
    const logger = Logger.init(cap.sink(), .warn);

    logger.debug("ignored", &.{});
    logger.info("ignored", &.{});
    try std.testing.expectEqual(@as(usize, 0), cap.lines.items.len);

    logger.warn("kept", &.{});
    logger.err("kept", &.{});
    try std.testing.expectEqual(@as(usize, 2), cap.lines.items.len);
    try std.testing.expectEqualStrings("WARN kept", cap.lines.items[0]);
    try std.testing.expectEqualStrings("ERROR kept", cap.lines.items[1]);
}

test "writerSink writes newline-terminated lines" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const logger = Logger.init(writerSink(&w), .info);

    logger.info("line1", &.{});
    logger.info("line2", &.{});
    try std.testing.expectEqualStrings("INFO line1\nINFO line2\n", buf[0..w.end]);
}

test "log middleware records request details" {
    var router = router_mod.Router.init(std.testing.allocator);
    defer router.deinit();
    try router.get("/health", okHandler);

    var cap = Capture.init(std.testing.allocator);
    defer cap.deinit();
    const logger = Logger.init(cap.sink(), .info);
    var mw = LogMiddleware.init(&logger);

    var pipeline = middleware.MiddlewarePipeline.init(std.testing.allocator);
    defer pipeline.deinit();
    try pipeline.useOnionCtx(&mw, LogMiddleware.handle);

    var req: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/health", .target = "/health" };
    const response = try pipeline.execute(&router, &req);
    try std.testing.expectEqualStrings("ok", response.body);

    const line = cap.last().?;
    try std.testing.expect(std.mem.startsWith(u8, line, "INFO request "));
    try std.testing.expect(std.mem.indexOf(u8, line, "method=get") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "path=/health") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "status=200") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "dur_us=") != null);
}

test "log middleware logs server errors at error level" {
    var router = router_mod.Router.init(std.testing.allocator);
    defer router.deinit();
    try router.get("/boom", errorHandler);

    var cap = Capture.init(std.testing.allocator);
    defer cap.deinit();
    const logger = Logger.init(cap.sink(), .info);
    var mw = LogMiddleware.init(&logger);

    var pipeline = middleware.MiddlewarePipeline.init(std.testing.allocator);
    defer pipeline.deinit();
    try pipeline.useOnionCtx(&mw, LogMiddleware.handle);

    var req: http.HttpRequest = .{ .allocator = std.testing.allocator, .method = .get, .path = "/boom", .target = "/boom" };
    _ = try pipeline.execute(&router, &req);

    const line = cap.last().?;
    try std.testing.expect(std.mem.startsWith(u8, line, "ERROR request "));
    try std.testing.expect(std.mem.indexOf(u8, line, "status=500") != null);
}

fn okHandler(_: *http.HttpRequest) anyerror!http.HttpResponse {
    return http.HttpResponse.text("ok");
}

fn errorHandler(_: *http.HttpRequest) anyerror!http.HttpResponse {
    return http.HttpResponse.serverError();
}

const zio = @import("zio");

const FileSinkState = struct {
    io: std.Io,
    path: []const u8,
    err: ?anyerror = null,
};

fn fileSinkImpl(state: *FileSinkState) anyerror!void {
    const io = state.io;
    var dir = std.Io.Dir.cwd();
    dir.deleteFile(io, state.path) catch {};
    defer dir.deleteFile(io, state.path) catch {};

    {
        var fs = try FileSink.open(io, state.path, .{});
        defer fs.close();
        const logger = Logger.init(fs.sink(), .info);
        logger.info("first", &.{.{ .key = "n", .value = "1" }});
        logger.debug("skipped", &.{}); // below min level
        logger.warn("second", &.{});
    }

    // Re-open in append mode and add one more line.
    {
        var fs = try FileSink.open(io, state.path, .{ .truncate = false });
        defer fs.close();
        const logger = Logger.init(fs.sink(), .info);
        logger.err("third", &.{});
    }

    var file = try dir.openFile(io, state.path, .{});
    defer file.close(io);
    var buf: [256]u8 = undefined;
    const n = try file.readPositionalAll(io, &buf, 0);
    const contents = buf[0..n];
    try std.testing.expectEqualStrings(
        "INFO first n=1\nWARN second\nERROR third\n",
        contents,
    );
}

fn fileSinkRoot(state: *FileSinkState) anyerror!void {
    const io = state.io;
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    const Wrapper = struct {
        fn run(s: *FileSinkState) std.Io.Cancelable!void {
            fileSinkImpl(s) catch |e| {
                s.err = e;
            };
        }
    };
    try group.concurrent(io, Wrapper.run, .{state});
    group.await(io) catch {};
    if (state.err) |e| return e;
}

test "FileSink appends structured lines and supports append mode" {
    var runtime = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();

    var state = FileSinkState{ .io = runtime.io(), .path = "zig-cache-zyra-log-filesink-test.log" };
    try fileSinkRoot(&state);
}

test "Level.fromLabel parses labels case-insensitively" {
    try std.testing.expectEqual(Level.debug, Level.fromLabel("DEBUG").?);
    try std.testing.expectEqual(Level.info, Level.fromLabel("info").?);
    try std.testing.expectEqual(Level.warn, Level.fromLabel("Warning").?);
    try std.testing.expectEqual(Level.err, Level.fromLabel("error").?);
    try std.testing.expect(Level.fromLabel("nope") == null);
}

test "LogChannel filters by its own runtime-adjustable level" {
    var cap = Capture.init(std.testing.allocator);
    defer cap.deinit();

    var channel = LogChannel.init("access", cap.sink(), .warn);
    channel.emit(.info, "ignored", &.{}); // below level
    channel.emit(.warn, "kept", &.{.{ .key = "k", .value = "v" }});
    try std.testing.expectEqual(@as(usize, 1), cap.lines.items.len);
    try std.testing.expectEqualStrings("WARN kept k=v", cap.lines.items[0]);

    // Lower the level at runtime; previously filtered level now passes.
    channel.setLevel(.debug);
    try std.testing.expectEqual(Level.debug, channel.level());
    channel.emit(.info, "now-visible", &.{});
    try std.testing.expectEqual(@as(usize, 2), cap.lines.items.len);
    try std.testing.expectEqualStrings("INFO now-visible", cap.lines.items[1]);
}

const AdminTestState = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    err: ?anyerror = null,
};

fn adminTestImpl(state: *AdminTestState) anyerror!void {
    const io = state.io;
    const alloc = state.allocator;

    var cap = Capture.init(alloc);
    defer cap.deinit();

    var registry = LogChannelRegistry.init(alloc);
    defer registry.deinit();

    // getOrCreate creates once, returns the same pointer thereafter.
    const access = try registry.getOrCreate(io, "access", cap.sink(), .info);
    const access2 = try registry.getOrCreate(io, "access", cap.sink(), .err);
    try std.testing.expectEqual(access, access2);
    try std.testing.expectEqual(Level.info, access.level()); // not overwritten
    _ = try registry.getOrCreate(io, "audit", cap.sink(), .warn);

    try std.testing.expect(registry.get(io, "access") != null);
    try std.testing.expect(registry.get(io, "missing") == null);

    var admin = LogAdmin.init(&registry);

    // GET returns each channel's level as JSON.
    {
        var req = http.HttpRequest.initParsed(alloc, "GET", "/admin/log-level", null, null, true);
        defer req.deinit();
        req.io = io;
        const res = try admin.handleGet(&req);
        defer alloc.free(res.body);
        try std.testing.expectEqual(http.HttpStatus.ok, res.status);

        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, res.body, .{});
        defer parsed.deinit();
        const channels = parsed.value.object.get("channels").?.object;
        try std.testing.expectEqualStrings("INFO", channels.get("access").?.string);
        try std.testing.expectEqualStrings("WARN", channels.get("audit").?.string);
    }

    // PUT adjusts a channel's level.
    {
        var req = http.HttpRequest.initParsed(alloc, "PUT", "/admin/log-level", "application/json", null, true);
        defer req.deinit();
        req.io = io;
        req.body_bytes =
            \\{"channel":"access","level":"ERROR"}
        ;
        const res = try admin.handlePut(&req);
        try std.testing.expectEqual(http.HttpStatus.ok, res.status);
        try std.testing.expectEqual(Level.err, access.level());
    }

    // PUT with unknown channel -> 404.
    {
        var req = http.HttpRequest.initParsed(alloc, "PUT", "/admin/log-level", "application/json", null, true);
        defer req.deinit();
        req.io = io;
        req.body_bytes =
            \\{"channel":"ghost","level":"INFO"}
        ;
        const res = try admin.handlePut(&req);
        try std.testing.expectEqual(http.HttpStatus.not_found, res.status);
    }

    // PUT with bad level -> 400.
    {
        var req = http.HttpRequest.initParsed(alloc, "PUT", "/admin/log-level", "application/json", null, true);
        defer req.deinit();
        req.io = io;
        req.body_bytes =
            \\{"channel":"access","level":"LOUD"}
        ;
        const res = try admin.handlePut(&req);
        try std.testing.expectEqual(http.HttpStatus.bad_request, res.status);
    }

    // matchesPath only matches the configured endpoint.
    try std.testing.expect(admin.matchesPath("/admin/log-level"));
    try std.testing.expect(!admin.matchesPath("/admin/other"));
    try std.testing.expect(!admin.matchesPath("/log-level"));
}

fn adminTestRoot(state: *AdminTestState) anyerror!void {
    const io = state.io;
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    const Wrapper = struct {
        fn run(s: *AdminTestState) std.Io.Cancelable!void {
            adminTestImpl(s) catch |e| {
                s.err = e;
            };
        }
    };
    try group.concurrent(io, Wrapper.run, .{state});
    group.await(io) catch {};
    if (state.err) |e| return e;
}

test "LogChannelRegistry and LogAdmin manage channel levels over HTTP" {
    var runtime = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();

    var state = AdminTestState{ .io = runtime.io(), .allocator = std.testing.allocator };
    try adminTestRoot(&state);
}
