//! WebSocket protocol (RFC 6455) — pure-Zig frame codec and handshake helpers.
//!
//! This module implements the parts of RFC 6455 that are self-contained and
//! fully testable without networking:
//!   * `computeAcceptKey` — derives the `Sec-WebSocket-Accept` value from the
//!     client's `Sec-WebSocket-Key`.
//!   * `Opcode` / `CloseCode` — protocol constants.
//!   * `Frame` — decoding (with client-mask handling) and encoding of frames.
//!
//! Streaming send/receive over a connection is provided by `WebSocketSession`,
//! which builds on the codec and reads/writes through `std.Io`.

const std = @import("std");

/// RFC 6455 §1.3 magic GUID appended to the client key before hashing.
pub const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// WebSocket opcodes (RFC 6455 §5.2).
pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,

    pub fn isControl(self: Opcode) bool {
        return (@intFromEnum(self) & 0x8) != 0;
    }
};

/// WebSocket close codes (RFC 6455 §7.4.1).
pub const CloseCode = enum(u16) {
    normal = 1000,
    going_away = 1001,
    protocol_error = 1002,
    unsupported_data = 1003,
    invalid_payload = 1007,
    policy_violation = 1008,
    message_too_big = 1009,
    internal_error = 1011,
    _,
};

/// Default maximum message size (1 MiB) to bound memory usage.
pub const default_max_message_size: usize = 1024 * 1024;

/// Computes the `Sec-WebSocket-Accept` header value for a given client key.
/// Writes the base64 result into `out` (must be >= 28 bytes) and returns the
/// written slice.
pub fn computeAcceptKey(client_key: []const u8, out: *[28]u8) []const u8 {
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(client_key);
    sha1.update(guid);
    var digest: [20]u8 = undefined;
    sha1.final(&digest);
    return std.base64.standard.Encoder.encode(out, &digest);
}

/// A decoded WebSocket frame header plus a slice into the payload.
pub const Frame = struct {
    fin: bool,
    rsv1: bool,
    opcode: Opcode,
    /// Payload bytes. For decoded frames this points into a caller-provided
    /// buffer that has already been unmasked.
    payload: []const u8,

    pub const DecodeError = error{
        Incomplete,
        PayloadTooLarge,
    };

    /// Attempts to decode a single frame from `data`. On success returns the
    /// decoded frame and the total number of bytes consumed. Masking (always
    /// present on client->server frames) is applied in place into `data`.
    ///
    /// Returns `error.Incomplete` if `data` does not yet contain the full
    /// frame, and `error.PayloadTooLarge` if the payload exceeds `max_payload`.
    pub fn decode(data: []u8, max_payload: usize) DecodeError!struct { frame: Frame, consumed: usize } {
        if (data.len < 2) return error.Incomplete;

        const b0 = data[0];
        const b1 = data[1];
        const fin = (b0 & 0x80) != 0;
        const rsv1 = (b0 & 0x40) != 0;
        const opcode: Opcode = @enumFromInt(@as(u4, @truncate(b0 & 0x0F)));
        const masked = (b1 & 0x80) != 0;
        const len7: u64 = b1 & 0x7F;

        var offset: usize = 2;
        var payload_len: u64 = len7;
        if (len7 == 126) {
            if (data.len < offset + 2) return error.Incomplete;
            payload_len = std.mem.readInt(u16, data[offset..][0..2], .big);
            offset += 2;
        } else if (len7 == 127) {
            if (data.len < offset + 8) return error.Incomplete;
            payload_len = std.mem.readInt(u64, data[offset..][0..8], .big);
            offset += 8;
        }

        if (payload_len > max_payload) return error.PayloadTooLarge;

        var mask: [4]u8 = .{ 0, 0, 0, 0 };
        if (masked) {
            if (data.len < offset + 4) return error.Incomplete;
            @memcpy(&mask, data[offset..][0..4]);
            offset += 4;
        }

        const plen: usize = @intCast(payload_len);
        if (data.len < offset + plen) return error.Incomplete;

        const payload = data[offset .. offset + plen];
        if (masked) {
            for (payload, 0..) |*byte, i| byte.* ^= mask[i % 4];
        }

        return .{
            .frame = .{ .fin = fin, .rsv1 = rsv1, .opcode = opcode, .payload = payload },
            .consumed = offset + plen,
        };
    }

    /// Encodes a server->client frame (unmasked, per RFC 6455 §5.1) into a
    /// freshly allocated buffer owned by the caller.
    pub fn encode(allocator: std.mem.Allocator, opcode: Opcode, payload: []const u8, fin: bool) ![]u8 {
        const header_len: usize = if (payload.len < 126)
            2
        else if (payload.len <= 0xFFFF)
            4
        else
            10;

        var buf = try allocator.alloc(u8, header_len + payload.len);
        buf[0] = (if (fin) @as(u8, 0x80) else 0) | @as(u8, @intFromEnum(opcode));

        if (payload.len < 126) {
            buf[1] = @intCast(payload.len);
        } else if (payload.len <= 0xFFFF) {
            buf[1] = 126;
            std.mem.writeInt(u16, buf[2..4], @intCast(payload.len), .big);
        } else {
            buf[1] = 127;
            std.mem.writeInt(u64, buf[2..10], @intCast(payload.len), .big);
        }

        @memcpy(buf[header_len..], payload);
        return buf;
    }
};

/// A received WebSocket message with its type.
pub const Message = struct {
    opcode: Opcode,
    data: []const u8,
};

/// A live WebSocket connection.
///
/// This is a thin wrapper over the standard library's
/// `std.http.Server.WebSocket`, which implements the RFC 6455 handshake and
/// frame read/write. The server constructs a session after a successful
/// upgrade and passes it to the registered handler.
///
/// Note: the underlying `readMessage` requires each message to fit in the
/// server's read buffer and does not reassemble fragmented (`fin == false`)
/// messages.
pub const WebSocketSession = struct {
    ws: *std.http.Server.WebSocket,
    open: bool = true,

    pub const ReceiveError = std.http.Server.WebSocket.ReadSmallTextMessageError;
    pub const SendError = std.Io.Writer.Error;

    /// Sends a UTF-8 text message.
    pub fn send(self: *WebSocketSession, text: []const u8) SendError!void {
        try self.ws.writeMessage(text, .text);
    }

    /// Sends a binary message.
    pub fn sendBinary(self: *WebSocketSession, data: []const u8) SendError!void {
        try self.ws.writeMessage(data, .binary);
    }

    /// Sends a ping frame with an optional payload (max 125 bytes).
    pub fn sendPing(self: *WebSocketSession, payload: []const u8) SendError!void {
        try self.ws.writeMessage(payload, .ping);
    }

    /// Receives the next message. Returns `null` when the peer closes the
    /// connection. The returned data points into the connection read buffer and
    /// is invalidated by the next `receive` call.
    pub fn receive(self: *WebSocketSession) ReceiveError!?Message {
        const msg = self.ws.readSmallMessage() catch |err| switch (err) {
            error.ConnectionClose => {
                self.open = false;
                return null;
            },
            else => return err,
        };
        return .{ .opcode = stdToOpcode(msg.opcode), .data = msg.data };
    }

    /// Whether the connection is still considered open.
    pub fn isOpen(self: *const WebSocketSession) bool {
        return self.open;
    }

    /// Sends a close frame with the given code and marks the session closed.
    pub fn close(self: *WebSocketSession, code: CloseCode) SendError!void {
        var payload: [2]u8 = undefined;
        std.mem.writeInt(u16, &payload, @intFromEnum(code), .big);
        self.ws.writeMessage(&payload, .connection_close) catch {};
        self.open = false;
    }
};

fn stdToOpcode(op: std.http.Server.WebSocket.Opcode) Opcode {
    return switch (op) {
        .continuation => .continuation,
        .text => .text,
        .binary => .binary,
        .connection_close => .close,
        .ping => .ping,
        .pong => .pong,
        _ => .text,
    };
}

test "computeAcceptKey matches RFC 6455 example" {
    // RFC 6455 §1.3 worked example.
    var out: [28]u8 = undefined;
    const accept = computeAcceptKey("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept);
}

test "Opcode.isControl" {
    try std.testing.expect(!Opcode.text.isControl());
    try std.testing.expect(!Opcode.binary.isControl());
    try std.testing.expect(Opcode.close.isControl());
    try std.testing.expect(Opcode.ping.isControl());
    try std.testing.expect(Opcode.pong.isControl());
}

test "Frame.encode small text frame" {
    const buf = try Frame.encode(std.testing.allocator, .text, "Hello", true);
    defer std.testing.allocator.free(buf);
    // FIN + text opcode, len 5, no mask, payload.
    try std.testing.expectEqual(@as(u8, 0x81), buf[0]);
    try std.testing.expectEqual(@as(u8, 5), buf[1]);
    try std.testing.expectEqualStrings("Hello", buf[2..]);
}

test "Frame.encode 16-bit length" {
    const payload = "x" ** 200;
    const buf = try Frame.encode(std.testing.allocator, .binary, payload, true);
    defer std.testing.allocator.free(buf);
    try std.testing.expectEqual(@as(u8, 0x82), buf[0]);
    try std.testing.expectEqual(@as(u8, 126), buf[1]);
    try std.testing.expectEqual(@as(u16, 200), std.mem.readInt(u16, buf[2..4], .big));
    try std.testing.expectEqual(@as(usize, 204), buf.len);
}

test "Frame.decode masked client frame" {
    // Client frame for "Hi": FIN+text, masked, len 2, mask 0x37fa213d.
    var data = [_]u8{
        0x81, 0x82, 0x37, 0xfa, 0x21, 0x3d,
        0x37 ^ 'H', 0xfa ^ 'i',
    };
    const res = try Frame.decode(&data, default_max_message_size);
    try std.testing.expect(res.frame.fin);
    try std.testing.expectEqual(Opcode.text, res.frame.opcode);
    try std.testing.expectEqualStrings("Hi", res.frame.payload);
    try std.testing.expectEqual(@as(usize, 8), res.consumed);
}

test "Frame.decode reports incomplete" {
    var data = [_]u8{0x81};
    try std.testing.expectError(error.Incomplete, Frame.decode(&data, default_max_message_size));
}

test "Frame.decode enforces max payload" {
    // len7 = 5 but max is 4.
    var data = [_]u8{ 0x81, 0x05, 'h', 'e', 'l', 'l', 'o' };
    try std.testing.expectError(error.PayloadTooLarge, Frame.decode(&data, 4));
}

test "encode/decode round trip" {
    // Encode a server frame, then mask it like a client and decode it back.
    const original = "round-trip payload";
    const server = try Frame.encode(std.testing.allocator, .text, original, true);
    defer std.testing.allocator.free(server);

    // Build a masked client frame from the same payload.
    var client: std.ArrayListUnmanaged(u8) = .empty;
    defer client.deinit(std.testing.allocator);
    try client.append(std.testing.allocator, 0x81);
    try client.append(std.testing.allocator, 0x80 | @as(u8, @intCast(original.len)));
    const mask = [4]u8{ 0x11, 0x22, 0x33, 0x44 };
    try client.appendSlice(std.testing.allocator, &mask);
    for (original, 0..) |c, i| try client.append(std.testing.allocator, c ^ mask[i % 4]);

    const res = try Frame.decode(client.items, default_max_message_size);
    try std.testing.expectEqualStrings(original, res.frame.payload);
    try std.testing.expectEqual(client.items.len, res.consumed);
}

const zio = @import("zio");

// End-to-end: a real WebSocket handshake + echo over a loopback connection
// driven by the zio runtime, exercising WebSocketSession.receive/send.
const E2eState = struct {
    io: std.Io,
    port: u16 = 0,
    received: [64]u8 = undefined,
    received_len: usize = 0,
    ok: bool = false,
};

fn e2eServer(state: *E2eState, listener: *std.Io.net.Server) std.Io.Cancelable!void {
    const io = state.io;
    const stream = listener.accept(io) catch return;
    defer stream.close(io);

    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    var writer = stream.writer(io, &wbuf);
    var server = std.http.Server.init(&reader.interface, &writer.interface);

    var req = server.receiveHead() catch return;
    const upgrade = req.upgradeRequested();
    const key = switch (upgrade) {
        .websocket => |k| k orelse return,
        else => return,
    };
    var socket = req.respondWebSocket(.{ .key = key }) catch return;
    socket.flush() catch return;

    var session = WebSocketSession{ .ws = &socket };
    const msg = (session.receive() catch return) orelse return;
    // Echo it straight back.
    session.send(msg.data) catch return;
    socket.flush() catch {};
}

fn e2eClient(state: *E2eState) std.Io.Cancelable!void {
    const io = state.io;

    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", state.port) catch return;
    const stream = addr.connect(io, .{ .mode = .stream }) catch return;
    defer stream.close(io);

    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    var writer = stream.writer(io, &wbuf);

    // Minimal WebSocket client handshake.
    const handshake =
        "GET /chat HTTP/1.1\r\n" ++
        "Host: 127.0.0.1\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n\r\n";
    writer.interface.writeAll(handshake) catch return;
    writer.interface.flush() catch return;

    // Read until end of response headers (\r\n\r\n).
    var header_buf: [1024]u8 = undefined;
    var header_len: usize = 0;
    while (header_len < header_buf.len) {
        const n = reader.interface.readSliceShort(header_buf[header_len .. header_len + 1]) catch return;
        if (n == 0) return;
        header_len += 1;
        if (header_len >= 4 and std.mem.eql(u8, header_buf[header_len - 4 .. header_len], "\r\n\r\n")) break;
    }

    // Send a masked text frame "ping".
    const payload = "ping";
    const mask = [4]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    var frame: [10]u8 = undefined;
    frame[0] = 0x81; // FIN + text
    frame[1] = 0x80 | @as(u8, payload.len); // masked + len
    @memcpy(frame[2..6], &mask);
    for (payload, 0..) |c, i| frame[6 + i] = c ^ mask[i % 4];
    writer.interface.writeAll(frame[0 .. 6 + payload.len]) catch return;
    writer.interface.flush() catch return;

    // Read the echoed (unmasked) server frame.
    var resp: [64]u8 = undefined;
    var resp_len: usize = 0;
    while (resp_len < 6) {
        const n = reader.interface.readSliceShort(resp[resp_len..]) catch return;
        if (n == 0) break;
        resp_len += n;
    }
    const decoded = Frame.decode(resp[0..resp_len], default_max_message_size) catch return;
    @memcpy(state.received[0..decoded.frame.payload.len], decoded.frame.payload);
    state.received_len = decoded.frame.payload.len;
    state.ok = decoded.frame.opcode == .text;
}

fn e2eRoot(state: *E2eState, listener: *std.Io.net.Server) anyerror!void {
    const io = state.io;
    state.port = listener.socket.address.getPort();

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, e2eServer, .{ state, listener });
    try group.concurrent(io, e2eClient, .{state});
    group.await(io) catch {};
}

test "websocket end-to-end handshake and echo" {
    var runtime = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();
    const io = runtime.io();

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var state = E2eState{ .io = io };
    try e2eRoot(&state, &listener);

    try std.testing.expect(state.ok);
    try std.testing.expectEqualStrings("ping", state.received[0..state.received_len]);
}
