//! WebSocket connection hub: registry, rooms, and broadcasting.
//!
//! Mirrors Hical's `WsHub` (`add`/`remove`/`join`/`leave`/`broadcast`/
//! `broadcastBinary`/`broadcastAll`/`sendTo`/`roomSize`).
//!
//! The hub does not own connections; it tracks them by an assigned
//! `ConnectionId` and routes messages through a `Sink` — a small, allocation-free
//! interface (function pointers + context) that decouples the hub from the
//! concrete transport. `Sink.fromSession` adapts a live
//! `websocket.WebSocketSession`; tests use an in-memory sink. All operations are
//! guarded by an `std.Io.Mutex`, so methods take an `io: std.Io` handle.

const std = @import("std");
const websocket = @import("websocket.zig");

pub const ConnectionId = u64;

/// Transport-agnostic message sink. Holds an opaque context and two send
/// functions. Send errors are swallowed by the hub during broadcast (a broken
/// peer must not abort delivery to the rest of the room).
pub const Sink = struct {
    ptr: *anyopaque,
    send_text: *const fn (*anyopaque, []const u8) anyerror!void,
    send_binary: *const fn (*anyopaque, []const u8) anyerror!void,

    /// Adapts a live WebSocket session into a sink.
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
    /// room name -> set of member connection ids
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

    /// Registers a connection and returns its assigned id.
    pub fn add(self: *WsHub, io: std.Io, sink: Sink) !ConnectionId {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const id = self.next_id;
        self.next_id += 1;
        try self.connections.put(self.allocator, id, .{ .sink = sink });
        return id;
    }

    /// Removes a connection from the hub and every room it belongs to.
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

    /// Adds a connection to a room (creating the room if needed). No-op if the
    /// connection id is unknown.
    pub fn join(self: *WsHub, io: std.Io, id: ConnectionId, room: []const u8) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const conn = self.connections.getPtr(id) orelse return;

        // Ensure the room exists and obtain the owned room-name key, which both
        // the room map and the connection's room set will reference.
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

    /// Removes a connection from a room.
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

    /// Sends a text message to every member of `room`, optionally skipping
    /// `exclude` (pass 0 to exclude nobody).
    pub fn broadcast(self: *WsHub, io: std.Io, room: []const u8, message: []const u8, exclude: ConnectionId) void {
        self.broadcastImpl(io, room, message, exclude, false);
    }

    /// Sends a binary message to every member of `room`.
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

    /// Sends a text message to every registered connection.
    pub fn broadcastAll(self: *WsHub, io: std.Io, message: []const u8, exclude: ConnectionId) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var it = self.connections.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.* == exclude) continue;
            entry.value_ptr.sink.deliver(message, false);
        }
    }

    /// Sends a text message to a single connection by id.
    pub fn sendTo(self: *WsHub, io: std.Io, id: ConnectionId, message: []const u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.connections.get(id)) |conn| {
            conn.sink.deliver(message, false);
        }
    }

    /// Number of members currently in `room`.
    pub fn roomSize(self: *WsHub, io: std.Io, room: []const u8) usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const members = self.rooms.get(room) orelse return 0;
        return members.count();
    }

    /// Number of registered connections.
    pub fn connectionCount(self: *WsHub, io: std.Io) usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.connections.count();
    }
};

// ----------------------------------------------------------------------------
// Tests (driven by a single-threaded zio runtime, since std.Io.Mutex needs io)
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

/// In-memory sink that records every message it receives, for assertions.
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

            // Joining twice is idempotent.
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
            // c is not in the room.

            hub.broadcast(io, "room", "hello", a); // exclude the sender

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
            // Empty room is cleaned up.
            try std.testing.expectEqual(@as(usize, 0), hub.roomSize(io, "room"));
            try std.testing.expectEqual(@as(usize, 0), hub.connectionCount(io));
        }
    }.body);
}
