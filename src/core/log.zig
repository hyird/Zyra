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

/// Request-logging middleware. Construct with `init(logger)` and register via
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
