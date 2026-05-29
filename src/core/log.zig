//! 结构化日志。
//!
//! Hical 日志栈的一个聚焦、完整实现的子集：
//!
//! - `Level`        - 带文本标签和排序的严重级别
//! - `Field`        - 一个结构化的键/值对（值为字符串）
//! - `Sink`         - 与传输无关的行 sink（函数指针 + 上下文）
//! - `writerSink`   - 把任意 `*std.Io.Writer` 适配为 `Sink`
//! - `Logger`       - 按级别过滤的结构化行日志器
//! - `LogMiddleware`- 上下文洋葱中间件，记录每个请求的 method、
//!   path、status 和耗时
//!
//! 行的格式为：
//!   `LEVEL message key1=value1 key2=value2`
//! 低于配置的最低级别的日志在任何格式化之前就被跳过。

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

    /// 解析级别标签（不区分大小写）。接受规范标签
    /// （`DEBUG`/`INFO`/`WARN`/`ERROR`）以及别名 `WARNING`。
    pub fn fromLabel(text: []const u8) ?Level {
        if (std.ascii.eqlIgnoreCase(text, "debug")) return .debug;
        if (std.ascii.eqlIgnoreCase(text, "info")) return .info;
        if (std.ascii.eqlIgnoreCase(text, "warn") or std.ascii.eqlIgnoreCase(text, "warning")) return .warn;
        if (std.ascii.eqlIgnoreCase(text, "error") or std.ascii.eqlIgnoreCase(text, "err")) return .err;
        return null;
    }
};

/// 一个结构化日志字段。值为字符串；数字请用调用方自己的缓冲区格式化
/// 后再传入。
pub const Field = struct {
    key: []const u8,
    value: []const u8,
};

/// 行 sink。`write` 收到的是一行完整格式化、但不含尾随换行的内容；
/// 由 sink 决定行终止符。错误会回报给日志器，由其吞掉（日志绝不能让
/// 调用方崩溃）。
pub const Sink = struct {
    ptr: *anyopaque,
    writeFn: *const fn (*anyopaque, []const u8) anyerror!void,

    fn write(self: Sink, line: []const u8) void {
        self.writeFn(self.ptr, line) catch {};
    }
};

/// 把任意 `*std.Io.Writer` 适配为 `Sink`。该 writer 的生命周期必须长于
/// sink。每行之后追加一个换行符。注意：刷新底层 writer 由调用方负责。
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

/// 一个使用 `std.Io` 文件 API 把日志行追加到文件的 `Sink`。
///
/// 每行在当前末尾偏移处写入并附带尾随换行，因此向不同 `FileSink` 写入的
/// 并发日志器永远不会在一行内交错。文件在 `open` 时被创建（默认会截断）；
/// 传入 `.{ .truncate = false }` 可保留并在已有内容之后追加。
///
/// `FileSink` 拥有底层的 `std.Io.File`，必须用 `close` 关闭。它的生命周期
/// 必须长于任何由其 `sink()` 构建的 `Logger`。
pub const FileSink = struct {
    io: std.Io,
    file: std.Io.File,
    offset: u64,

    pub const OpenOptions = struct {
        /// 打开时把已有文件截断为零长度。为 false 时，sink 在当前内容
        /// 之后追加。
        truncate: bool = true,
    };

    /// 创建或打开 `path` 以追加日志行。`path` 通过 `std.Io.Dir.cwd()`
    /// 相对于当前工作目录解析。
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

/// 异步、批量的文件 sink（双缓冲 + 后台 fiber）。
///
/// 前端的 `write` 调用把行追加到由 `std.Io.Mutex` 保护的内存缓冲区；一个
/// 后台 fiber（由 `start` 生成）周期性地交换缓冲区，并把累积的字节用一次
/// 按位置写一次性刷到磁盘。这样把处理请求的 fiber 与磁盘延迟解耦。
///
/// 背压：当待刷缓冲区超过 `backpressure_limit` 时，新行会被丢弃并计入
/// `dropped`（用 `droppedCount` 读取），而不是阻塞调用方。日志前调用一次
/// `start(io)`，结束时调用 `stop(io)` 以刷出剩余数据并 join 后台 fiber。
/// sink 绑定传给 `start` 的 `io`；`write` 用它来锁 mutex，因此所有日志都
/// 必须发生在同一运行时上。
pub const AsyncFileSink = struct {
    allocator: std.mem.Allocator,
    file: FileSink,
    io: std.Io = undefined,
    mutex: std.Io.Mutex = .init,
    cur_buf: std.ArrayListUnmanaged(u8) = .empty,
    flush_buf: std.ArrayListUnmanaged(u8) = .empty,
    flush_event: std.Io.Event = .unset,
    running: std.atomic.Value(bool) = .init(false),
    dropped: std.atomic.Value(u64) = .init(0),
    group: std.Io.Group = .init,
    flush_interval_ms: u64 = 1000,
    backpressure_limit: usize = 8 * 1024 * 1024,

    pub const Options = struct {
        /// 打开时截断文件（见 `FileSink.OpenOptions`）。
        truncate: bool = true,
        flush_interval_ms: u64 = 1000,
        backpressure_limit: usize = 8 * 1024 * 1024,
    };

    /// 打开 `path` 并准备一个异步 sink。日志前调用 `start(io)` 启动后台
    /// 刷写器。
    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8, options: Options) !AsyncFileSink {
        const file = try FileSink.open(io, path, .{ .truncate = options.truncate });
        return .{
            .allocator = allocator,
            .file = file,
            .flush_interval_ms = options.flush_interval_ms,
            .backpressure_limit = options.backpressure_limit,
        };
    }

    /// 启动后台刷写 fiber。必须在任何日志之前、并且在 `stop` 之前恰好
    /// 调用一次。
    pub fn start(self: *AsyncFileSink, io: std.Io) void {
        self.io = io;
        self.running.store(true, .release);
        self.group.async(io, backgroundLoop, .{self});
    }

    /// 通知后台 fiber 排空并退出，join 它，刷出任何残留字节，释放缓冲区，
    /// 并关闭文件。
    pub fn stop(self: *AsyncFileSink, io: std.Io) void {
        self.running.store(false, .release);
        self.flush_event.set(io);
        self.group.await(io) catch {};
        // 最终排空在最后一次循环迭代之后追加的所有内容。
        self.drainOnce(io);
        self.cur_buf.deinit(self.allocator);
        self.flush_buf.deinit(self.allocator);
        self.file.close();
    }

    /// 因背压而至今丢弃的行数。
    pub fn droppedCount(self: *const AsyncFileSink) u64 {
        return self.dropped.load(.acquire);
    }

    fn writeLine(ptr: *anyopaque, line: []const u8) anyerror!void {
        const self: *AsyncFileSink = @ptrCast(@alignCast(ptr));
        const io = self.io;
        self.mutex.lockUncancelable(io);
        const over_limit = self.cur_buf.items.len + line.len + 1 > self.backpressure_limit;
        if (over_limit) {
            self.mutex.unlock(io);
            _ = self.dropped.fetchAdd(1, .acq_rel);
            return;
        }
        self.cur_buf.appendSlice(self.allocator, line) catch {
            self.mutex.unlock(io);
            _ = self.dropped.fetchAdd(1, .acq_rel);
            return;
        };
        self.cur_buf.append(self.allocator, '\n') catch {};
        self.mutex.unlock(io);
        self.flush_event.set(io);
    }

    /// 在锁内把 `cur_buf` 换入 `flush_buf`，然后在锁外把捕获到的字节写到
    /// 磁盘，这样前端写入者就不会因 I/O 被阻塞。
    fn drainOnce(self: *AsyncFileSink, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        if (self.cur_buf.items.len == 0) {
            self.mutex.unlock(io);
            return;
        }
        const tmp = self.cur_buf;
        self.cur_buf = self.flush_buf;
        self.flush_buf = tmp;
        self.cur_buf.clearRetainingCapacity();
        self.mutex.unlock(io);

        self.file.file.writePositionalAll(io, self.flush_buf.items, self.file.offset) catch {};
        self.file.offset += self.flush_buf.items.len;
    }

    fn backgroundLoop(self: *AsyncFileSink) void {
        const io = self.io;
        const timeout: std.Io.Timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(@intCast(self.flush_interval_ms)),
            .clock = .awake,
        } };
        while (self.running.load(.acquire)) {
            // 等待刷新间隔到时或显式唤醒，然后重置，使下一轮迭代从干净
            // 状态开始。
            self.flush_event.waitTimeout(io, timeout) catch {};
            self.flush_event.reset();
            self.drainOnce(io);
        }
    }

    pub fn sink(self: *AsyncFileSink) Sink {
        return .{ .ptr = self, .writeFn = writeLine };
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

    /// 以 `level` 记录一条带可选结构化字段的消息。当 `level` 低于最低级别
    /// 时完全跳过格式化。格式化后的行构建在固定的 1 KiB 栈缓冲区上；更长的
    /// 行会被截断。
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

/// 一个具名的日志通道，拥有自己的可在运行时调整的级别和 sink。
///
/// 通道把不同类别的日志（如 `access`、`audit`、`perf`）路由到不同的目的地，
/// 并让运维人员独立地调节每个类别的详尽程度。级别以原子方式存储，因此可
/// 在请求正在记录日志时于运行时更改（例如通过 log-admin 端点）。
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

    /// 在该通道上输出一条结构化行，按通道当前级别过滤。格式与 `Logger.log`
    /// 一致，低于阈值时完全跳过。
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

/// 具名 `LogChannel` 的线程安全注册表。
///
/// 通道通常在启动时创建，并在运行时按名字查找。注册表拥有每个通道
/// （堆分配），并在 `deinit` 时释放它们。通道名会被复制到注册表自有的
/// 存储中。一个 mutex 保护该 map；按通道的级别更改使用通道自己的原子，
/// 无需加锁。
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

    /// 返回名为 `name` 的已有通道，或用 `sink` 和 `min_level` 创建一个。
    /// 返回的指针在注册表的生命周期内保持稳定。`io` 用于 mutex 加锁。
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

    /// 返回名为 `name` 的通道，不存在则返回 null。
    pub fn get(self: *LogChannelRegistry, io: std.Io, name: []const u8) ?*LogChannel {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.channels.get(name);
    }

    /// 在持有注册表锁的同时，对每个已注册通道调用 `callback(ctx, channel)`。
    /// 用于只读遍历（例如列出各级别）。
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


/// 通过 `attach(server)` 或 `server.useOnionCtx(&mw, LogMiddleware.handle)`
/// 注册。每个请求记录一行：method、path、status，以及以微秒计的耗时。
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

/// log-admin 端点的可选认证检查。返回 `null` 表示放行请求；返回一个
/// 响应（如 401/403）则拒绝它。
pub const AdminAuthCheck = *const fn (*http.HttpRequest) anyerror!?http.HttpResponse;

/// 作为上下文中间件的运行时日志级别管理。
///
/// 拦截 `prefix`（默认 `/admin`）下的两个端点：
///   - `GET  {prefix}/log-level`  -> JSON `{ "channels": { name: "LEVEL", ... } }`
///   - `PUT  {prefix}/log-level`  -> 请求体 `{ "channel": "access", "level": "WARN" }`
///     调整单个通道的级别；成功响应 200，输入错误响应 400，通道未知响应 404。
///
/// 到其他路径的请求会透传给 `next`。通过 `attach(server)` 注册
/// （使用 `server.useOnionCtx`）。
///
/// 警告：这些端点会改变日志行为。生产环境中你必须提供一个 `auth` 检查，
/// 以防止未授权的级别更改。
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

    /// 该管理实例处理的端点路径（`{prefix}/log-level`）。按需针对调用方
    /// 缓冲区计算，以避免分配。
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
// 测试
// ----------------------------------------------------------------------------


const router_mod = @import("router.zig");

/// 把每一行都捕获进自有缓冲区的测试 sink。
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
        logger.debug("skipped", &.{}); // 低于最低级别
        logger.warn("second", &.{});
    }

    // 以追加模式重新打开并再加一行。
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

const AsyncSinkState = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    err: ?anyerror = null,
    contents_ok: bool = false,
};

fn asyncSinkImpl(state: *AsyncSinkState) anyerror!void {
    const io = state.io;
    var dir = std.Io.Dir.cwd();
    dir.deleteFile(io, state.path) catch {};
    defer dir.deleteFile(io, state.path) catch {};

    var sink = try AsyncFileSink.open(state.allocator, io, state.path, .{ .flush_interval_ms = 10 });
    sink.start(io);
    const logger = Logger.init(sink.sink(), .info);
    logger.info("alpha", &.{});
    logger.warn("beta", &.{});
    logger.debug("skipped", &.{}); // 低于最低级别，永远不会到达 sink
    sink.stop(io); // 排空并 join 后台 fiber

    var file = try dir.openFile(io, state.path, .{});
    defer file.close(io);
    var buf: [256]u8 = undefined;
    const n = try file.readPositionalAll(io, &buf, 0);
    state.contents_ok = std.mem.eql(u8, buf[0..n], "INFO alpha\nWARN beta\n");
}

fn asyncSinkRoot(state: *AsyncSinkState) anyerror!void {
    const io = state.io;
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    const Wrapper = struct {
        fn run(s: *AsyncSinkState) std.Io.Cancelable!void {
            asyncSinkImpl(s) catch |e| {
                s.err = e;
            };
        }
    };
    try group.concurrent(io, Wrapper.run, .{state});
    group.await(io) catch {};
    if (state.err) |e| return e;
}

test "AsyncFileSink batches lines from a background fiber" {
    var runtime = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();

    var state = AsyncSinkState{ .io = runtime.io(), .allocator = std.testing.allocator, .path = "zig-cache-zyra-log-asyncsink-test.log" };
    try asyncSinkRoot(&state);
    try std.testing.expect(state.contents_ok);
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
    channel.emit(.info, "ignored", &.{}); // 低于级别
    channel.emit(.warn, "kept", &.{.{ .key = "k", .value = "v" }});
    try std.testing.expectEqual(@as(usize, 1), cap.lines.items.len);
    try std.testing.expectEqualStrings("WARN kept k=v", cap.lines.items[0]);

    // 在运行时降低级别；之前被过滤的级别现在通过了。
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

    // getOrCreate 只创建一次，之后返回同一个指针。
    const access = try registry.getOrCreate(io, "access", cap.sink(), .info);
    const access2 = try registry.getOrCreate(io, "access", cap.sink(), .err);
    try std.testing.expectEqual(access, access2);
    try std.testing.expectEqual(Level.info, access.level()); // 未被覆盖
    _ = try registry.getOrCreate(io, "audit", cap.sink(), .warn);

    try std.testing.expect(registry.get(io, "access") != null);
    try std.testing.expect(registry.get(io, "missing") == null);

    var admin = LogAdmin.init(&registry);

    // GET 以 JSON 返回每个通道的级别。
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

    // PUT 调整某个通道的级别。
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

    // 未知通道的 PUT -> 404。
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

    // 级别错误的 PUT -> 400。
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

    // matchesPath 只匹配配置的端点。
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
