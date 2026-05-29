//! WebSocket 连接 hub：注册表、房间和广播。
//!
//! 镜像 Hical 的 `WsHub`（`add`/`remove`/`join`/`leave`/`broadcast`/
//! `broadcastBinary`/`broadcastAll`/`sendTo`/`roomSize`).
//!
//! hub 不拥有连接；它通过分配的 `ConnectionId` 跟踪连接，并通过 `Sink` 路由
//! 消息。`Sink` 是一个小型、无分配接口（函数指针 + 上下文），把 hub 与具体
//! 传输解耦。`Sink.fromSession` 适配一个存活的 `websocket.WebSocketSession`；
//! 测试使用内存 sink。所有操作都由 `std.Io.Mutex` 保护，因此方法接收一个
//! `io: std.Io` 句柄。

const std = @import("std");
const websocket = @import("websocket.zig");

pub const ConnectionId = u64;

/// 与传输无关的消息 sink。持有一个不透明上下文和两个发送函数。广播时发送
/// 错误会被 hub 吞掉（坏掉的 peer 不能中止向房间其余成员的投递）。
pub const Sink = struct {
    ptr: *anyopaque,
    send_text: *const fn (*anyopaque, []const u8) anyerror!void,
    send_binary: *const fn (*anyopaque, []const u8) anyerror!void,

    /// 把一个存活的 WebSocket 会话适配为 sink。
    pub fn fromSession(session: *websocket.WebSocketSession) Sink {
        const Adapter = struct {
            fn text(ptr: *anyopaque, msg: []const u8) anyerror!void {
                const s: *websocket.WebSocketSession = @ptrCast(@alignCast(ptr));
                try s.send(msg);
            }
            fn binary(ptr: *anyopaque, data: []const u8) anyerror!void {
                const s: *websocket.WebSocketSession = @ptrCast(@alignCast(ptr));
                try s.sendBinary(data);
            }
        };
        return .{ .ptr = session, .send_text = Adapter.text, .send_binary = Adapter.binary };
    }

    fn deliver(self: Sink, payload: []const u8, is_binary: bool) void {
        if (is_binary) {
            self.send_binary(self.ptr, payload) catch {};
        } else {
            self.send_text(self.ptr, payload) catch {};
        }
    }
};

const RoomSet = std.StringHashMapUnmanaged(void);

const Connection = struct {
    sink: Sink,
    rooms: RoomSet = .empty,
};

pub const WsHub = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    connections: std.AutoHashMapUnmanaged(ConnectionId, Connection) = .empty,
    /// 房间名 -> 成员连接 id 集合
    rooms: std.StringHashMapUnmanaged(std.AutoHashMapUnmanaged(ConnectionId, void)) = .empty,
    next_id: ConnectionId = 1,

    pub fn init(allocator: std.mem.Allocator) WsHub {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *WsHub, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        var conn_it = self.connections.iterator();
        while (conn_it.next()) |entry| {
            self.freeConnectionRooms(entry.value_ptr);
        }
        self.connections.deinit(self.allocator);

        var room_it = self.rooms.iterator();
        while (room_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.rooms.deinit(self.allocator);
        self.mutex.unlock(io);
    }

    fn freeConnectionRooms(self: *WsHub, conn: *Connection) void {
        conn.rooms.deinit(self.allocator);
    }

    /// 注册一个连接并返回分配给它的 id。
    pub fn add(self: *WsHub, io: std.Io, sink: Sink) !ConnectionId {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const id = self.next_id;
        self.next_id += 1;
        try self.connections.put(self.allocator, id, .{ .sink = sink });
        return id;
    }

    /// 从 hub 及其所属的每个房间中移除一个连接。
    pub fn remove(self: *WsHub, io: std.Io, id: ConnectionId) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const conn = self.connections.getPtr(id) orelse return;
        var it = conn.rooms.iterator();
        while (it.next()) |entry| {
            self.leaveRoomLocked(entry.key_ptr.*, id);
        }
        conn.rooms.deinit(self.allocator);
        _ = self.connections.remove(id);
    }

    /// 把一个连接加入房间（必要时创建房间）。若连接 id 未知则不执行任何操作。
    pub fn join(self: *WsHub, io: std.Io, id: ConnectionId, room: []const u8) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const conn = self.connections.getPtr(id) orelse return;

        // 确保房间存在，并取得自有的房间名 key；房间 map 和连接的房间集合都会
        // 引用它。
        const room_gop = try self.rooms.getOrPut(self.allocator, room);
        if (!room_gop.found_existing) {
            const owned = self.allocator.dupe(u8, room) catch |err| {
                _ = self.rooms.remove(room);
                return err;
            };
            room_gop.key_ptr.* = owned;
            room_gop.value_ptr.* = .empty;
        }
        const owned_key = room_gop.key_ptr.*;

        try conn.rooms.put(self.allocator, owned_key, {});
        try room_gop.value_ptr.put(self.allocator, id, {});
    }

    /// 从房间中移除一个连接。
    pub fn leave(self: *WsHub, io: std.Io, id: ConnectionId, room: []const u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.connections.getPtr(id)) |conn| {
            _ = conn.rooms.remove(room);
        }
        self.leaveRoomLocked(room, id);
    }

    fn leaveRoomLocked(self: *WsHub, room: []const u8, id: ConnectionId) void {
        const room_entry = self.rooms.getEntry(room) orelse return;
        _ = room_entry.value_ptr.remove(id);
        if (room_entry.value_ptr.count() == 0) {
            const key = room_entry.key_ptr.*;
            room_entry.value_ptr.deinit(self.allocator);
            _ = self.rooms.remove(room);
            self.allocator.free(key);
        }
    }

    /// 向 `room` 的每个成员发送文本消息，可选择跳过 `exclude`（传 0 表示不跳过）。
    pub fn broadcast(self: *WsHub, io: std.Io, room: []const u8, message: []const u8, exclude: ConnectionId) void {
        self.broadcastImpl(io, room, message, exclude, false);
    }

    /// 向 `room` 的每个成员发送二进制消息。
    pub fn broadcastBinary(self: *WsHub, io: std.Io, room: []const u8, data: []const u8, exclude: ConnectionId) void {
        self.broadcastImpl(io, room, data, exclude, true);
    }

    fn broadcastImpl(self: *WsHub, io: std.Io, room: []const u8, payload: []const u8, exclude: ConnectionId, is_binary: bool) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const members = self.rooms.get(room) orelse return;
        var it = members.iterator();
        while (it.next()) |entry| {
            const id = entry.key_ptr.*;
            if (id == exclude) continue;
            if (self.connections.get(id)) |conn| {
                conn.sink.deliver(payload, is_binary);
            }
        }
    }

    /// 向每个已注册连接发送文本消息。
    pub fn broadcastAll(self: *WsHub, io: std.Io, message: []const u8, exclude: ConnectionId) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var it = self.connections.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.* == exclude) continue;
            entry.value_ptr.sink.deliver(message, false);
        }
    }

    /// 按 id 向单个连接发送文本消息。
    pub fn sendTo(self: *WsHub, io: std.Io, id: ConnectionId, message: []const u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.connections.get(id)) |conn| {
            conn.sink.deliver(message, false);
        }
    }

    /// `room` 中当前的成员数。
    pub fn roomSize(self: *WsHub, io: std.Io, room: []const u8) usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const members = self.rooms.get(room) orelse return 0;
        return members.count();
    }

    /// 已注册连接数。
    pub fn connectionCount(self: *WsHub, io: std.Io) usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.connections.count();
    }
};

// ----------------------------------------------------------------------------
// 测试（由单线程 zio 运行时驱动，因为 std.Io.Mutex 需要 io）
// ----------------------------------------------------------------------------

const zio = @import("zio");

const TestResult = struct {
    err: ?anyerror = null,
    fn check(self: TestResult) !void {
        if (self.err) |e| return e;
    }
};

fn runOnIo(comptime func: anytype) !void {
    var runtime = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();
    const io = runtime.io();

    var result = TestResult{};
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    const Wrapper = struct {
        fn run(r: *TestResult, the_io: std.Io) std.Io.Cancelable!void {
            func(the_io) catch |e| {
                r.err = e;
            };
        }
    };
    try group.concurrent(io, Wrapper.run, .{ &result, io });
    group.await(io) catch {};
    try result.check();
}

/// 内存 sink，记录收到的每条消息以便断言。
const Recorder = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayListUnmanaged([]u8) = .empty,

    fn init(allocator: std.mem.Allocator) Recorder {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Recorder) void {
        for (self.messages.items) |m| self.allocator.free(m);
        self.messages.deinit(self.allocator);
    }

    fn record(ptr: *anyopaque, msg: []const u8) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        const copy = try self.allocator.dupe(u8, msg);
        try self.messages.append(self.allocator, copy);
    }

    fn sink(self: *Recorder) Sink {
        return .{ .ptr = self, .send_text = record, .send_binary = record };
    }

    fn last(self: *const Recorder) ?[]const u8 {
        if (self.messages.items.len == 0) return null;
        return self.messages.items[self.messages.items.len - 1];
    }
};

test "add assigns increasing ids and tracks count" {
    try runOnIo(struct {
        fn body(io: std.Io) anyerror!void {
            var hub = WsHub.init(std.testing.allocator);
            defer hub.deinit(io);

            var r1 = Recorder.init(std.testing.allocator);
            defer r1.deinit();
            var r2 = Recorder.init(std.testing.allocator);
            defer r2.deinit();

            const a = try hub.add(io, r1.sink());
            const b = try hub.add(io, r2.sink());
            try std.testing.expectEqual(@as(ConnectionId, 1), a);
            try std.testing.expectEqual(@as(ConnectionId, 2), b);
            try std.testing.expectEqual(@as(usize, 2), hub.connectionCount(io));

            hub.remove(io, a);
            try std.testing.expectEqual(@as(usize, 1), hub.connectionCount(io));
        }
    }.body);
}

test "join and roomSize track membership" {
    try runOnIo(struct {
        fn body(io: std.Io) anyerror!void {
            var hub = WsHub.init(std.testing.allocator);
            defer hub.deinit(io);

            var r1 = Recorder.init(std.testing.allocator);
            defer r1.deinit();
            var r2 = Recorder.init(std.testing.allocator);
            defer r2.deinit();

            const a = try hub.add(io, r1.sink());
            const b = try hub.add(io, r2.sink());

            try std.testing.expectEqual(@as(usize, 0), hub.roomSize(io, "lobby"));
            try hub.join(io, a, "lobby");
            try hub.join(io, b, "lobby");
            try std.testing.expectEqual(@as(usize, 2), hub.roomSize(io, "lobby"));

            // 加入两次是幂等的。
            try hub.join(io, a, "lobby");
            try std.testing.expectEqual(@as(usize, 2), hub.roomSize(io, "lobby"));

            hub.leave(io, a, "lobby");
            try std.testing.expectEqual(@as(usize, 1), hub.roomSize(io, "lobby"));
        }
    }.body);
}

test "broadcast delivers to room members except excluded" {
    try runOnIo(struct {
        fn body(io: std.Io) anyerror!void {
            var hub = WsHub.init(std.testing.allocator);
            defer hub.deinit(io);

            var r1 = Recorder.init(std.testing.allocator);
            defer r1.deinit();
            var r2 = Recorder.init(std.testing.allocator);
            defer r2.deinit();
            var r3 = Recorder.init(std.testing.allocator);
            defer r3.deinit();

            const a = try hub.add(io, r1.sink());
            const b = try hub.add(io, r2.sink());
            const c = try hub.add(io, r3.sink());
            try hub.join(io, a, "room");
            try hub.join(io, b, "room");
            // c 不在房间中。

            hub.broadcast(io, "room", "hello", a); // 排除发送者

            try std.testing.expectEqual(@as(usize, 0), r1.messages.items.len);
            try std.testing.expectEqualStrings("hello", r2.last().?);
            try std.testing.expectEqual(@as(usize, 0), r3.messages.items.len);
            _ = c;
        }
    }.body);
}

test "broadcastAll reaches every connection" {
    try runOnIo(struct {
        fn body(io: std.Io) anyerror!void {
            var hub = WsHub.init(std.testing.allocator);
            defer hub.deinit(io);

            var r1 = Recorder.init(std.testing.allocator);
            defer r1.deinit();
            var r2 = Recorder.init(std.testing.allocator);
            defer r2.deinit();

            _ = try hub.add(io, r1.sink());
            _ = try hub.add(io, r2.sink());

            hub.broadcastAll(io, "ping", 0);
            try std.testing.expectEqualStrings("ping", r1.last().?);
            try std.testing.expectEqualStrings("ping", r2.last().?);
        }
    }.body);
}

test "sendTo targets a single connection" {
    try runOnIo(struct {
        fn body(io: std.Io) anyerror!void {
            var hub = WsHub.init(std.testing.allocator);
            defer hub.deinit(io);

            var r1 = Recorder.init(std.testing.allocator);
            defer r1.deinit();
            var r2 = Recorder.init(std.testing.allocator);
            defer r2.deinit();

            const a = try hub.add(io, r1.sink());
            _ = try hub.add(io, r2.sink());

            hub.sendTo(io, a, "direct");
            try std.testing.expectEqualStrings("direct", r1.last().?);
            try std.testing.expectEqual(@as(usize, 0), r2.messages.items.len);
        }
    }.body);
}

test "remove evicts connection from its rooms" {
    try runOnIo(struct {
        fn body(io: std.Io) anyerror!void {
            var hub = WsHub.init(std.testing.allocator);
            defer hub.deinit(io);

            var r1 = Recorder.init(std.testing.allocator);
            defer r1.deinit();

            const a = try hub.add(io, r1.sink());
            try hub.join(io, a, "room");
            try std.testing.expectEqual(@as(usize, 1), hub.roomSize(io, "room"));

            hub.remove(io, a);
            // 空房间会被清理。
            try std.testing.expectEqual(@as(usize, 0), hub.roomSize(io, "room"));
            try std.testing.expectEqual(@as(usize, 0), hub.connectionCount(io));
        }
    }.body);
}
